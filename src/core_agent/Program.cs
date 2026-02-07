using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using CoreAgent.Cache;

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    cts.Cancel();
};

var config = CoreConfig.Load();
var cache = new LocalCache(config.CacheDir);
PostgresCache? pgCache = null;
if (!string.IsNullOrWhiteSpace(config.CorePgUrl))
{
    try
    {
        pgCache = new PostgresCache(config.CorePgUrl, config.CorePgSchema);
        await pgCache.EnsureAsync(cts.Token);
        await pgCache.LoadIntoAsync(cache, cts.Token);
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[core-agent] pg cache init failed: {ex.Message}");
        pgCache = null;
    }
}
Console.WriteLine($"[core-agent] device={config.DeviceId} ws={config.WsUrl}");

while (!cts.Token.IsCancellationRequested)
{
    try
    {
        await RunAsync(config, cache, pgCache, cts.Token);
    }
    catch (OperationCanceledException)
    {
        break;
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[core-agent] error: {ex.Message}");
        try
        {
            await Task.Delay(2000, cts.Token);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}

static async Task RunAsync(CoreConfig config, LocalCache cache, PostgresCache? pgCache, CancellationToken ct)
{
    using var ws = new ClientWebSocket();
    await ws.ConnectAsync(new Uri(config.WsUrl), ct);

    var sendLock = new SemaphoreSlim(1, 1);
    var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };

    await SendAsync(ws, sendLock, new
    {
        type = "auth",
        device_id = config.DeviceId,
        token = config.Token,
        capabilities = new[] { "scale_read", "print_label", "rfid_write", "health" }
    }, ct);

    var authed = false;
    var helloSent = false;
    using var statusCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
    var statusTask = Task.Run(() => StatusLoop(ws, sendLock, http, config, cache, pgCache, statusCts.Token), statusCts.Token);

    // initial cache sync
    await SyncCacheAsync(http, config, cache, pgCache, ct);

    while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
    {
        var msg = await ReceiveTextAsync(ws, ct);
        if (msg == null)
        {
            break;
        }

        try
        {
            using var doc = JsonDocument.Parse(msg);
            var root = doc.RootElement;
            var type = root.GetProperty("type").GetString();

            if (type == "auth")
            {
                var ok = root.TryGetProperty("ok", out var okProp) && okProp.GetBoolean();
                authed = ok;
                if (ok && !helloSent)
                {
                    await SendAsync(ws, sendLock, new
                    {
                        type = "hello",
                        device_id = config.DeviceId,
                        agent = "core-agent",
                        capabilities = new[] { "scale_read", "print_label", "rfid_write", "health" }
                    }, ct);
                    helloSent = true;
                }
            }
            else if (type == "hello")
            {
                // ignore server hello
            }
            else if (type == "ping")
            {
                await SendAsync(ws, sendLock, new { type = "pong" }, ct);
            }
            else if (type == "command")
            {
                var requestId = root.GetProperty("request_id").GetString() ?? "";
                var name = root.GetProperty("name").GetString() ?? "";
                var payload = root.TryGetProperty("payload", out var p) ? p : default;
                await HandleCommand(ws, sendLock, http, config, cache, pgCache, requestId, name, payload, ct);
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[core-agent] decode error: {ex.Message}");
        }
    }

    statusCts.Cancel();
    try { await statusTask; } catch { }
}

static async Task HandleCommand(ClientWebSocket ws, SemaphoreSlim sendLock, HttpClient http, CoreConfig config,
    LocalCache cache, PostgresCache? pgCache, string requestId, string name, JsonElement payload, CancellationToken ct)
{
    try
    {
        switch (name)
        {
            case "scale_read":
            {
                var weight = await ReadScaleAsync(http, config.ZebraUrl, ct);
                await SendResult(ws, sendLock, requestId, true, new { weight }, ct);
                break;
            }
            case "print_label":
            {
                // EPC conflict check via LCE
                if (payload.TryGetProperty("epc", out var epcProp))
                {
                    var epcVal = epcProp.GetString();
                    if (!string.IsNullOrWhiteSpace(epcVal))
                    {
                        var exists = await CheckEpcAsync(http, config, epcVal!, ct);
                        if (exists)
                        {
                            await SendResult(ws, sendLock, requestId, false, new { error = "epc_conflict" }, ct);
                            break;
                        }
                    }
                }
                var result = await PrintLabelAsync(http, config.ZebraUrl, payload, ct);
                await SendResult(ws, sendLock, requestId, true, result, ct);
                break;
            }
            case "rfid_write":
            {
                var epc = payload.TryGetProperty("epc", out var epcProp) ? epcProp.GetString() : null;
                if (string.IsNullOrWhiteSpace(epc))
                {
                    await SendResult(ws, sendLock, requestId, false, new { error = "epc missing" }, ct);
                    break;
                }
                var result = await RfidWriteAsync(http, config.RfidUrl, epc!, ct);
                await RegisterEpcAsync(http, config, epc!, ct);
                await SendResult(ws, sendLock, requestId, true, result, ct);
                break;
            }
            case "health":
            {
                var status = await BuildStatusAsync(http, config, cache, pgCache, ct);
                await SendResult(ws, sendLock, requestId, true, status, ct);
                break;
            }
            case "sync_cache":
            {
                await SyncCacheAsync(http, config, cache, pgCache, ct);
                await SendResult(ws, sendLock, requestId, true, new { ok = true }, ct);
                break;
            }
            default:
                await SendResult(ws, sendLock, requestId, false, new { error = "unknown command" }, ct);
                break;
        }
    }
    catch (Exception ex)
    {
        await SendResult(ws, sendLock, requestId, false, new { error = ex.Message }, ct);
    }
}

static async Task StatusLoop(ClientWebSocket ws, SemaphoreSlim sendLock, HttpClient http, CoreConfig config, LocalCache cache, PostgresCache? pgCache, CancellationToken ct)
{
    while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
    {
        try
        {
            var status = await BuildStatusAsync(http, config, cache, pgCache, ct);
            await SendAsync(ws, sendLock, new { type = "status", data = status }, ct);
        }
        catch { }

        try
        {
            await Task.Delay(config.StatusIntervalMs, ct);
        }
        catch (OperationCanceledException)
        {
            break;
        }
    }
}

static async Task<object> BuildStatusAsync(HttpClient http, CoreConfig config, LocalCache cache, PostgresCache? pgCache, CancellationToken ct)
{
    var zebra = await HealthCheckAsync(http, $"{config.ZebraUrl}/api/v1/health", ct);
    var rfid = await HealthCheckAsync(http, $"{config.RfidUrl}/api/status", ct);
    return new
    {
        ts = DateTime.UtcNow,
        zebra_ok = zebra.ok,
        zebra_error = zebra.error,
        rfid_ok = rfid.ok,
        rfid_error = rfid.error,
        cache = new
        {
            items = cache.Items.Count,
            warehouses = cache.Warehouses.Count,
            drafts = cache.Drafts.Count,
            pg = pgCache != null
        }
    };
}

static async Task<(bool ok, string? error)> HealthCheckAsync(HttpClient http, string url, CancellationToken ct)
{
    try
    {
        using var resp = await http.GetAsync(url, ct);
        if (!resp.IsSuccessStatusCode)
        {
            return (false, $"{(int)resp.StatusCode} {resp.ReasonPhrase}");
        }
        return (true, null);
    }
    catch (Exception ex)
    {
        return (false, ex.Message);
    }
}

static async Task<double> ReadScaleAsync(HttpClient http, string baseUrl, CancellationToken ct)
{
    var url = $"{baseUrl}/api/v1/scale";
    var json = await http.GetStringAsync(url, ct);
    using var doc = JsonDocument.Parse(json);
    if (doc.RootElement.TryGetProperty("weight", out var w) && w.TryGetDouble(out var weight))
    {
        return weight;
    }
    throw new InvalidOperationException("scale weight missing");
}

static async Task<object> PrintLabelAsync(HttpClient http, string baseUrl, JsonElement payload, CancellationToken ct)
{
    if (!payload.TryGetProperty("epc", out var epcProp))
    {
        throw new InvalidOperationException("epc missing");
    }

    var epc = epcProp.GetString() ?? string.Empty;
    var copies = payload.TryGetProperty("copies", out var c) && c.TryGetInt32(out var cv) ? cv : 1;
    var human = payload.TryGetProperty("print_human", out var h) ? h.GetBoolean() : true;

    object labelFields;
    if (payload.TryGetProperty("label_fields", out var lf))
    {
        labelFields = JsonSerializer.Deserialize<object>(lf.GetRawText()) ?? new { };
    }
    else
    {
        var productId = payload.TryGetProperty("product_id", out var p) ? p.GetString() : epc;
        var weight = payload.TryGetProperty("weight_kg", out var w) && w.TryGetDouble(out var wg) ? wg : 0.0;
        labelFields = new
        {
            product_name = productId,
            weight_kg = weight.ToString("0.###"),
            epc_hex = epc
        };
    }

    var body = new
    {
        epc,
        copies,
        printHumanReadable = human,
        labelFields
    };

    var url = $"{baseUrl}/api/v1/encode";
    var resp = await PostJsonAsync(http, url, body, ct);
    return resp;
}

static async Task<object> RfidWriteAsync(HttpClient http, string baseUrl, string newEpc, CancellationToken ct)
{
    var statusJson = await http.GetStringAsync($"{baseUrl}/api/status", ct);
    using var statusDoc = JsonDocument.Parse(statusJson);
    if (!statusDoc.RootElement.TryGetProperty("status", out var status) ||
        !status.TryGetProperty("lastTag", out var last) ||
        !last.TryGetProperty("epcId", out var epcProp))
    {
        throw new InvalidOperationException("RFID tag not detected");
    }

    var targetEpc = epcProp.GetString();
    if (string.IsNullOrWhiteSpace(targetEpc))
    {
        throw new InvalidOperationException("RFID tag not detected");
    }

    var body = new
    {
        epc = targetEpc,
        mem = 1,
        wordPtr = 2,
        password = "00000000",
        data = newEpc
    };

    var resp = await PostJsonAsync(http, $"{baseUrl}/api/write", body, ct);
    return resp;
}

static async Task<object> PostJsonAsync(HttpClient http, string url, object body, CancellationToken ct)
{
    var json = JsonSerializer.Serialize(body);
    using var content = new StringContent(json, Encoding.UTF8, "application/json");
    using var resp = await http.PostAsync(url, content, ct);
    var respBody = await resp.Content.ReadAsStringAsync(ct);
    if (!resp.IsSuccessStatusCode)
    {
        throw new InvalidOperationException($"{(int)resp.StatusCode} {resp.ReasonPhrase} {respBody}");
    }
    if (string.IsNullOrWhiteSpace(respBody))
    {
        return new { ok = true };
    }
    try
    {
        return JsonSerializer.Deserialize<object>(respBody) ?? new { ok = true };
    }
    catch
    {
        return new { ok = true };
    }
}

static async Task SyncCacheAsync(HttpClient http, CoreConfig config, LocalCache cache, PostgresCache? pgCache, CancellationToken ct)
{
    var itemsJson = await http.GetStringAsync($"{config.ApiBase}/api/cache/items?limit=200", ct);
    var warehousesJson = await http.GetStringAsync($"{config.ApiBase}/api/cache/warehouses?limit=200", ct);
    var draftsJson = await http.GetStringAsync($"{config.ApiBase}/api/cache/stock_drafts", ct);

    using var itemsDoc = JsonDocument.Parse(itemsJson);
    using var warehousesDoc = JsonDocument.Parse(warehousesJson);
    using var draftsDoc = JsonDocument.Parse(draftsJson);

    var items = new List<ItemRow>();
    foreach (var item in itemsDoc.RootElement.GetProperty("items").EnumerateArray())
    {
        items.Add(new ItemRow(
            item.GetProperty("name").GetString() ?? "",
            item.TryGetProperty("item_name", out var name) ? name.GetString() : null,
            item.TryGetProperty("stock_uom", out var uom) ? uom.GetString() : null,
            item.TryGetProperty("disabled", out var dis) && dis.GetBoolean()
        ));
    }

    var warehouses = new List<WarehouseRow>();
    foreach (var wh in warehousesDoc.RootElement.GetProperty("warehouses").EnumerateArray())
    {
        warehouses.Add(new WarehouseRow(
            wh.GetProperty("name").GetString() ?? "",
            wh.TryGetProperty("warehouse_name", out var wname) ? wname.GetString() : null,
            wh.TryGetProperty("disabled", out var dis) && dis.GetBoolean(),
            wh.TryGetProperty("is_group", out var grp) && grp.GetBoolean()
        ));
    }

    var drafts = new List<StockDraftRow>();
    if (draftsDoc.RootElement.TryGetProperty("stock_drafts", out var draftsArr))
    {
        foreach (var d in draftsArr.EnumerateArray())
        {
            drafts.Add(new StockDraftRow(
                d.GetProperty("name").GetString() ?? "",
                d.TryGetProperty("purpose", out var pur) ? pur.GetString() : null,
                d.TryGetProperty("from_warehouse", out var fw) ? fw.GetString() : null,
                d.TryGetProperty("to_warehouse", out var tw) ? tw.GetString() : null,
                d.TryGetProperty("docstatus", out var ds) ? ds.GetInt32() : 0
            ));
        }
    }

    cache.ReplaceItems(items);
    cache.ReplaceWarehouses(warehouses);
    cache.ReplaceDrafts(drafts);

    if (pgCache != null)
    {
        try
        {
            await pgCache.ReplaceItemsAsync(items, ct);
            await pgCache.ReplaceWarehousesAsync(warehouses, ct);
            await pgCache.ReplaceDraftsAsync(drafts, ct);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[core-agent] pg cache update failed: {ex.Message}");
        }
    }
}

static async Task<bool> CheckEpcAsync(HttpClient http, CoreConfig config, string epc, CancellationToken ct)
{
    var url = $"{config.ApiBase}/api/epc/check?epc={WebUtility.UrlEncode(epc)}";
    var json = await http.GetStringAsync(url, ct);
    using var doc = JsonDocument.Parse(json);
    var root = doc.RootElement;
    if (root.TryGetProperty("local_exists", out var local) && local.GetBoolean()) return true;
    if (root.TryGetProperty("erp_exists", out var erp) && erp.GetBoolean()) return true;
    return false;
}

static async Task RegisterEpcAsync(HttpClient http, CoreConfig config, string epc, CancellationToken ct)
{
    var url = $"{config.ApiBase}/api/epc/register";
    await PostJsonAsync(http, url, new { epc, source = "core", status = "used" }, ct);
}

static async Task SendResult(ClientWebSocket ws, SemaphoreSlim sendLock, string requestId, bool ok, object data, CancellationToken ct)
{
    var payload = new Dictionary<string, object?>
    {
        ["type"] = "result",
        ["request_id"] = requestId,
        ["ok"] = ok
    };
    if (ok)
    {
        payload["data"] = data;
    }
    else
    {
        payload["error"] = data;
    }
    await SendAsync(ws, sendLock, payload, ct);
}

static async Task SendAsync(ClientWebSocket ws, SemaphoreSlim sendLock, object payload, CancellationToken ct)
{
    var json = JsonSerializer.Serialize(payload);
    var bytes = Encoding.UTF8.GetBytes(json);
    await sendLock.WaitAsync(ct);
    try
    {
        await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, ct);
    }
    finally
    {
        sendLock.Release();
    }
}

static async Task<string?> ReceiveTextAsync(ClientWebSocket ws, CancellationToken ct)
{
    var buffer = new ArraySegment<byte>(new byte[8192]);
    using var ms = new MemoryStream();

    while (true)
    {
        var result = await ws.ReceiveAsync(buffer, ct);
        if (result.MessageType == WebSocketMessageType.Close)
        {
            return null;
        }
        if (result.Count > 0)
        {
            ms.Write(buffer.Array!, buffer.Offset, result.Count);
        }
        if (result.EndOfMessage)
        {
            break;
        }
    }

    return Encoding.UTF8.GetString(ms.ToArray());
}

record CoreConfig(
    string WsUrl,
    string DeviceId,
    string Token,
    string ZebraUrl,
    string RfidUrl,
    string ApiBase,
    string CorePgUrl,
    string CorePgSchema,
    string CacheDir,
    int StatusIntervalMs)
{
    public static CoreConfig Load()
    {
        var wsUrl = Environment.GetEnvironmentVariable("CORE_WS_URL") ?? "ws://127.0.0.1:4000/ws/core";
        var deviceId = Environment.GetEnvironmentVariable("CORE_DEVICE_ID") ?? "CORE-01";
        var token = Environment.GetEnvironmentVariable("LCE_CORE_TOKEN") ?? "";
        var zebraUrl = NormalizeUrl(Environment.GetEnvironmentVariable("ZEBRA_URL") ?? "http://127.0.0.1:18000");
        var rfidUrl = NormalizeUrl(Environment.GetEnvironmentVariable("RFID_URL") ?? "http://127.0.0.1:8787");
        var apiBase = NormalizeUrl(Environment.GetEnvironmentVariable("LCE_API_BASE") ?? "http://127.0.0.1:4000");
        var corePgUrl = Environment.GetEnvironmentVariable("CORE_PG_URL") ?? "";
        var corePgSchema = Environment.GetEnvironmentVariable("CORE_PG_SCHEMA") ?? "core_cache";
        var cacheDir = Environment.GetEnvironmentVariable("CORE_CACHE_DIR") ?? Path.Combine(AppContext.BaseDirectory, "cache");
        var statusMs = ParseInt(Environment.GetEnvironmentVariable("CORE_STATUS_MS"), 10000);

        return new CoreConfig(wsUrl, deviceId, token, zebraUrl, rfidUrl, apiBase, corePgUrl, corePgSchema, cacheDir, statusMs);
    }

    private static int ParseInt(string? value, int fallback)
    {
        if (int.TryParse(value, out var n) && n > 0)
        {
            return n;
        }
        return fallback;
    }

    private static string NormalizeUrl(string value)
    {
        return value.TrimEnd('/');
    }
}
