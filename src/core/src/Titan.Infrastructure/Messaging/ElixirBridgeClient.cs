using System.Net.Http.Json;
using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Messaging;

public interface IElixirBridgeClient
{
    Task<bool> ConnectAsync(string elixirUrl, string apiToken);
    Task<T?> GetAsync<T>(string endpoint);
    Task<bool> PostAsync<T>(string endpoint, T data);
    Task<bool> SyncWeightRecordsAsync(IEnumerable<object> records);
}

public class ElixirBridgeClient : IElixirBridgeClient
{
    private readonly HttpClient _httpClient;
    private readonly ILogger<ElixirBridgeClient> _logger;

    public ElixirBridgeClient(ILogger<ElixirBridgeClient> logger)
    {
        _httpClient = new HttpClient();
        _logger = logger;
    }

    public Task<bool> ConnectAsync(string elixirUrl, string apiToken)
    {
        _httpClient.BaseAddress = new Uri(elixirUrl.TrimEnd('/'));
        _httpClient.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiToken);

        _logger.LogInformation("Connected to Elixir bridge: {Url}", elixirUrl);
        return Task.FromResult(true);
    }

    public async Task<T?> GetAsync<T>(string endpoint)
    {
        try
        {
            var response = await _httpClient.GetAsync($"/api/{endpoint}");
            if (response.IsSuccessStatusCode)
                return await response.Content.ReadFromJsonAsync<T>();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "GET request failed: {Endpoint}", endpoint);
        }
        return default;
    }

    public async Task<bool> PostAsync<T>(string endpoint, T data)
    {
        try
        {
            var response = await _httpClient.PostAsJsonAsync($"/api/{endpoint}", data);
            return response.IsSuccessStatusCode;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "POST request failed: {Endpoint}", endpoint);
            return false;
        }
    }

    public async Task<bool> SyncWeightRecordsAsync(IEnumerable<object> records)
        => await PostAsync("sync/records", records);
}
