// ============================================
// TITAN.INFRASTRUCTURE - Infrastructure Layer
// ============================================
// File: src/Titan.Infrastructure/Titan.Infrastructure.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Titan.Infrastructure</RootNamespace>
    <LangVersion>14.0</LangVersion>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../Titan.Domain/Titan.Domain.csproj" />
    <ProjectReference Include="../Titan.Core/Titan.Core.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Npgsql.EntityFrameworkCore.PostgreSQL" Version="10.0.0-preview.1" />
    <PackageReference Include="Microsoft.EntityFrameworkCore" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Dapper" Version="2.1.35" />
    <PackageReference Include="System.IO.Ports" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="LibUsbDotNet" Version="2.2.29" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: src/Titan.Infrastructure/Persistence/TitanDbContext.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;

namespace Titan.Infrastructure.Persistence;

public class TitanDbContext : DbContext
{
    public DbSet<Product> Products => Set<Product>();
    public DbSet<Batch> Batches => Set<Batch>();
    public DbSet<WeightRecord> WeightRecords => Set<WeightRecord>();
    public DbSet<EpcSequence> EpcSequences => Set<EpcSequence>();

    public TitanDbContext(DbContextOptions<TitanDbContext> options) : base(options)
    {
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Product>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Name).HasMaxLength(255).IsRequired();
            entity.Property(e => e.WarehouseId).HasMaxLength(64).IsRequired();
            entity.HasIndex(e => e.WarehouseId);
            entity.HasIndex(e => new { e.WarehouseId, e.IsReceived, e.CanIssue });
        });

        modelBuilder.Entity<Batch>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.Name).HasMaxLength(255).IsRequired();
            entity.Property(e => e.WarehouseId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.Status).HasConversion<string>().HasMaxLength(20);
            entity.HasIndex(e => e.Status);
            entity.HasIndex(e => new { e.Status, e.StartedAt });
        });

        modelBuilder.Entity<WeightRecord>(entity =>
        {
            entity.HasKey(e => e.Id);
            entity.Property(e => e.BatchId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.ProductId).HasMaxLength(64).IsRequired();
            entity.Property(e => e.Unit).HasMaxLength(10).IsRequired();
            entity.Property(e => e.EpcCode).HasMaxLength(24).IsRequired();
            entity.HasIndex(e => e.BatchId);
            entity.HasIndex(e => e.IsSynced);
            entity.HasIndex(e => e.EpcCode).IsUnique();
        });

        modelBuilder.Entity<EpcSequence>(entity =>
        {
            entity.HasKey(e => e.Prefix);
            entity.Property(e => e.Prefix).HasMaxLength(12);
        });
    }
}

public class EpcSequence
{
    public string Prefix { get; set; } = string.Empty;
    public long LastValue { get; set; }
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
}

// ============================================
// File: src/Titan.Infrastructure/Persistence/Repositories/ProductRepository.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class ProductRepository : IProductRepository
{
    private readonly TitanDbContext _context;

    public ProductRepository(TitanDbContext context)
    {
        _context = context;
    }

    public async Task<Product?> GetByIdAsync(string id, CancellationToken ct = default)
    {
        return await _context.Products.FindAsync(new object[] { id }, ct);
    }

    public async Task<IReadOnlyList<Product>> GetAllAsync(CancellationToken ct = default)
    {
        return await _context.Products.ToListAsync(ct);
    }

    public async Task<IReadOnlyList<Product>> GetByWarehouseAsync(string warehouseId, CancellationToken ct = default)
    {
        return await _context.Products
            .Where(p => p.WarehouseId == warehouseId)
            .ToListAsync(ct);
    }

    public async Task<IReadOnlyList<Product>> GetAvailableForIssueAsync(string warehouseId, CancellationToken ct = default)
    {
        return await _context.Products
            .Where(p => p.WarehouseId == warehouseId && p.IsReceived && p.CanIssue)
            .ToListAsync(ct);
    }

    public async Task AddAsync(Product entity, CancellationToken ct = default)
    {
        await _context.Products.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(Product entity, CancellationToken ct = default)
    {
        _context.Products.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.Products.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}

// ============================================
// File: src/Titan.Infrastructure/Persistence/Repositories/BatchRepository.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class BatchRepository : IBatchRepository
{
    private readonly TitanDbContext _context;

    public BatchRepository(TitanDbContext context)
    {
        _context = context;
    }

    public async Task<Batch?> GetByIdAsync(string id, CancellationToken ct = default)
    {
        return await _context.Batches.FindAsync(new object[] { id }, ct);
    }

    public async Task<IReadOnlyList<Batch>> GetAllAsync(CancellationToken ct = default)
    {
        return await _context.Batches.ToListAsync(ct);
    }

    public async Task<Batch?> GetActiveAsync(CancellationToken ct = default)
    {
        return await _context.Batches
            .FirstOrDefaultAsync(b => b.Status == BatchStatus.Running, ct);
    }

    public async Task AddAsync(Batch entity, CancellationToken ct = default)
    {
        await _context.Batches.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(Batch entity, CancellationToken ct = default)
    {
        _context.Batches.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.Batches.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}

// ============================================
// File: src/Titan.Infrastructure/Persistence/Repositories/WeightRecordRepository.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Persistence.Repositories;

public class WeightRecordRepository : IWeightRecordRepository
{
    private readonly TitanDbContext _context;

    public WeightRecordRepository(TitanDbContext context)
    {
        _context = context;
    }

    public async Task<WeightRecord?> GetByIdAsync(string id, CancellationToken ct = default)
    {
        return await _context.WeightRecords.FindAsync(new object[] { id }, ct);
    }

    public async Task<IReadOnlyList<WeightRecord>> GetAllAsync(CancellationToken ct = default)
    {
        return await _context.WeightRecords.ToListAsync(ct);
    }

    public async Task<IReadOnlyList<WeightRecord>> GetUnsyncedAsync(CancellationToken ct = default)
    {
        return await _context.WeightRecords
            .Where(r => !r.IsSynced)
            .OrderBy(r => r.RecordedAt)
            .ToListAsync(ct);
    }

    public async Task MarkAsSyncedAsync(string id, CancellationToken ct = default)
    {
        var record = await GetByIdAsync(id, ct);
        if (record != null)
        {
            record.MarkAsSynced();
            await _context.SaveChangesAsync(ct);
        }
    }

    public async Task AddAsync(WeightRecord entity, CancellationToken ct = default)
    {
        await _context.WeightRecords.AddAsync(entity, ct);
        await _context.SaveChangesAsync(ct);
    }

    public async Task UpdateAsync(WeightRecord entity, CancellationToken ct = default)
    {
        _context.WeightRecords.Update(entity);
        await _context.SaveChangesAsync(ct);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        var entity = await GetByIdAsync(id, ct);
        if (entity != null)
        {
            _context.WeightRecords.Remove(entity);
            await _context.SaveChangesAsync(ct);
        }
    }
}

// ============================================
// File: src/Titan.Infrastructure/Cache/MemoryCacheService.cs
// ============================================
using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using Titan.Domain.Interfaces;

namespace Titan.Infrastructure.Cache;

public class MemoryCacheService : ICacheService
{
    private readonly IMemoryCache _cache;
    private readonly JsonSerializerOptions _jsonOptions;

    public MemoryCacheService(IMemoryCache cache)
    {
        _cache = cache;
        _jsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
    }

    public Task<T?> GetAsync<T>(string key, CancellationToken ct = default) where T : class
    {
        if (_cache.TryGetValue(key, out var value) && value is T typedValue)
        {
            return Task.FromResult<T?>(typedValue);
        }
        return Task.FromResult<T?>(null);
    }

    public Task SetAsync<T>(string key, T value, TimeSpan? expiration = null, CancellationToken ct = default) where T : class
    {
        var options = new MemoryCacheEntryOptions();
        if (expiration.HasValue)
        {
            options.AbsoluteExpirationRelativeToNow = expiration.Value;
        }
        else
        {
            options.AbsoluteExpirationRelativeToNow = TimeSpan.FromHours(1);
        }
        
        _cache.Set(key, value, options);
        return Task.CompletedTask;
    }

    public Task RemoveAsync(string key, CancellationToken ct = default)
    {
        _cache.Remove(key);
        return Task.CompletedTask;
    }

    public Task<bool> ExistsAsync(string key, CancellationToken ct = default)
    {
        return Task.FromResult(_cache.TryGetValue(key, out _));
    }
}

// ============================================
// File: src/Titan.Infrastructure/Hardware/Scale/IScalePort.cs
// ============================================
namespace Titan.Infrastructure.Hardware.Scale;

public interface IScalePort : IAsyncDisposable
{
    bool IsConnected { get; }
    Task<bool> ConnectAsync(string portName, int baudRate = 9600, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);
    IAsyncEnumerable<ScaleReading> ReadAsync(CancellationToken ct = default);
}

public sealed record ScaleReading(
    double Value,
    string Unit,
    bool IsStable,
    DateTime Timestamp
);

// ============================================
// File: src/Titan.Infrastructure/Hardware/Scale/SerialScalePort.cs
// ============================================
using System.IO.Ports;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Hardware.Scale;

public partial class SerialScalePort : IScalePort
{
    private SerialPort? _serialPort;
    private readonly ILogger<SerialScalePort> _logger;
    private readonly TimeSpan _readTimeout = TimeSpan.FromMilliseconds(100);

    public bool IsConnected => _serialPort?.IsOpen ?? false;

    public SerialScalePort(ILogger<SerialScalePort> logger)
    {
        _logger = logger;
    }

    public Task<bool> ConnectAsync(string portName, int baudRate = 9600, CancellationToken ct = default)
    {
        try
        {
            _serialPort = new SerialPort(portName, baudRate)
            {
                Parity = Parity.None,
                DataBits = 8,
                StopBits = StopBits.One,
                ReadTimeout = (int)_readTimeout.TotalMilliseconds,
                WriteTimeout = 1000
            };
            
            _serialPort.Open();
            _logger.LogInformation("Scale connected on {Port}", portName);
            return Task.FromResult(true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to scale on {Port}", portName);
            return Task.FromResult(false);
        }
    }

    public Task DisconnectAsync(CancellationToken ct = default)
    {
        _serialPort?.Close();
        _serialPort?.Dispose();
        _serialPort = null;
        _logger.LogInformation("Scale disconnected");
        return Task.CompletedTask;
    }

    public async IAsyncEnumerable<ScaleReading> ReadAsync(CancellationToken ct = default)
    {
        if (_serialPort == null || !IsConnected)
            yield break;

        var buffer = new byte[256];
        var lineBuffer = new List<byte>();

        while (!ct.IsCancellationRequested && IsConnected)
        {
            try
            {
                var bytesRead = await _serialPort.BaseStream.ReadAsync(buffer, 0, buffer.Length, ct);
                
                for (int i = 0; i < bytesRead; i++)
                {
                    var b = buffer[i];
                    if (b == '\n' || b == '\r')
                    {
                        if (lineBuffer.Count > 0)
                        {
                            var line = System.Text.Encoding.ASCII.GetString(lineBuffer.ToArray());
                            if (TryParseReading(line, out var reading))
                            {
                                yield return reading;
                            }
                            lineBuffer.Clear();
                        }
                    }
                    else
                    {
                        lineBuffer.Add(b);
                    }
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error reading from scale");
                await Task.Delay(100, ct);
            }
        }
    }

    private static bool TryParseReading(string line, out ScaleReading reading)
    {
        reading = null!;
        
        // Common formats: "ST,GS,   1.234,kg", "1.234 kg", "+001.234kg"
        var match = ScaleRegex().Match(line);
        if (!match.Success)
            return false;

        var valueStr = match.Groups["value"].Value;
        var unit = match.Groups["unit"].Value.ToLowerInvariant();
        var stable = match.Groups["stable"].Success || line.Contains("ST");

        if (!double.TryParse(valueStr, System.Globalization.NumberStyles.Any, 
            System.Globalization.CultureInfo.InvariantCulture, out var value))
            return false;

        reading = new ScaleReading(value, unit, stable, DateTime.UtcNow);
        return true;
    }

    [GeneratedRegex(@"(?<stable>ST)?.*?(?<value>[+-]?\d+\.?\d*)\s*(?<unit>kg|g|lb|oz)", RegexOptions.IgnoreCase)]
    private static partial Regex ScaleRegex();

    public ValueTask DisposeAsync()
    {
        DisconnectAsync().Wait();
        return ValueTask.CompletedTask;
    }
}

// ============================================
// File: src/Titan.Infrastructure/Hardware/Printer/IPrinterTransport.cs
// ============================================
namespace Titan.Infrastructure.Hardware.Printer;

public interface IPrinterTransport : IAsyncDisposable
{
    bool IsConnected { get; }
    bool SupportsStatusQuery { get; }
    
    Task<bool> ConnectAsync(string connectionString, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);
    Task<PrintResult> SendAsync(string zplData, CancellationToken ct = default);
    Task<PrinterStatus?> QueryStatusAsync(CancellationToken ct = default);
}

public sealed record PrintResult(
    bool Success,
    string? ErrorMessage = null,
    string? JobId = null
);

public sealed record PrinterStatus(
    bool IsReady,
    bool IsPaused,
    bool HasError,
    bool PaperOut,
    bool RibbonOut,
    bool HeadOpen,
    string? ErrorMessage = null
);

// ============================================
// File: src/Titan.Infrastructure/Hardware/Printer/DeviceFilePrinter.cs
// ============================================
using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Hardware.Printer;

public class DeviceFilePrinter : IPrinterTransport
{
    private readonly ILogger<DeviceFilePrinter> _logger;
    private string? _devicePath;
    private FileStream? _fileStream;

    public bool IsConnected => _fileStream != null;
    public bool SupportsStatusQuery => false;

    public DeviceFilePrinter(ILogger<DeviceFilePrinter> logger)
    {
        _logger = logger;
    }

    public Task<bool> ConnectAsync(string connectionString, CancellationToken ct = default)
    {
        try
        {
            _devicePath = connectionString;
            _fileStream = new FileStream(_devicePath, FileMode.Open, FileAccess.Write, FileShare.None);
            _logger.LogInformation("Printer connected: {Path}", _devicePath);
            return Task.FromResult(true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to printer: {Path}", connectionString);
            return Task.FromResult(false);
        }
    }

    public Task DisconnectAsync(CancellationToken ct = default)
    {
        _fileStream?.Dispose();
        _fileStream = null;
        _logger.LogInformation("Printer disconnected");
        return Task.CompletedTask;
    }

    public async Task<PrintResult> SendAsync(string zplData, CancellationToken ct = default)
    {
        if (_fileStream == null)
            return new PrintResult(false, "Printer not connected");

        try
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(zplData);
            await _fileStream.WriteAsync(bytes, ct);
            await _fileStream.FlushAsync(ct);
            
            _logger.LogDebug("Sent {Bytes} bytes to printer", bytes.Length);
            return new PrintResult(true, JobId: Guid.NewGuid().ToString("N")[..8]);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send data to printer");
            return new PrintResult(false, ex.Message);
        }
    }

    public Task<PrinterStatus?> QueryStatusAsync(CancellationToken ct = default)
    {
        // Device file printer doesn't support status query
        return Task.FromResult<PrinterStatus?>(null);
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync();
    }
}

// ============================================
// File: src/Titan.Infrastructure/Services/EpcGenerator.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Titan.Core.Services;
using Titan.Domain.ValueObjects;
using Titan.Infrastructure.Persistence;

namespace Titan.Infrastructure.Services;

public class EpcGenerator : IEpcGenerator
{
    private readonly TitanDbContext _context;
    private readonly string _prefix;

    public EpcGenerator(TitanDbContext context, string prefix = "3034257BF7194E4")
    {
        _context = context;
        _prefix = prefix;
    }

    public async Task<string> GenerateNextAsync()
    {
        await using var transaction = await _context.Database.BeginTransactionAsync();
        
        try
        {
            var sequence = await _context.EpcSequences
                .FirstOrDefaultAsync(s => s.Prefix == _prefix);

            if (sequence == null)
            {
                sequence = new EpcSequence
                {
                    Prefix = _prefix,
                    LastValue = 0,
                    UpdatedAt = DateTime.UtcNow
                };
                _context.EpcSequences.Add(sequence);
            }

            sequence.LastValue++;
            sequence.UpdatedAt = DateTime.UtcNow;
            
            await _context.SaveChangesAsync();
            await transaction.CommitAsync();

            var epc = EpcCode.Create(_prefix, sequence.LastValue);
            return epc.Value;
        }
        catch
        {
            await transaction.RollbackAsync();
            throw;
        }
    }

    public async Task<long> GetCurrentCounterAsync()
    {
        var sequence = await _context.EpcSequences
            .FirstOrDefaultAsync(s => s.Prefix == _prefix);
        
        return sequence?.LastValue ?? 0;
    }
}

// ============================================
// File: src/Titan.Infrastructure/Messaging/ElixirBridgeClient.cs
// ============================================
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
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
    private string? _apiToken;

    public ElixirBridgeClient(ILogger<ElixirBridgeClient> logger)
    {
        _httpClient = new HttpClient();
        _logger = logger;
    }

    public Task<bool> ConnectAsync(string elixirUrl, string apiToken)
    {
        _httpClient.BaseAddress = new Uri(elixirUrl.TrimEnd('/'));
        _apiToken = apiToken;
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
            {
                return await response.Content.ReadFromJsonAsync<T>();
            }
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
    {
        return await PostAsync("sync/records", records);
    }
}
