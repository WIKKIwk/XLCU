// ============================================
// TITAN.HOST - Entry Point
// ============================================
// File: src/Titan.Host/Titan.Host.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Titan.Host</RootNamespace>
    <LangVersion>14.0</LangVersion>
    <PublishSingleFile>true</PublishSingleFile>
    <SelfContained>true</SelfContained>
    <RuntimeIdentifier>linux-x64</RuntimeIdentifier>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../Titan.Domain/Titan.Domain.csproj" />
    <ProjectReference Include="../Titan.Core/Titan.Core.csproj" />
    <ProjectReference Include="../Titan.Infrastructure/Titan.Infrastructure.csproj" />
    <ProjectReference Include="../Titan.TUI/Titan.TUI.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.Hosting" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Microsoft.Extensions.Logging.Console" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.Design" Version="10.0.0-preview.1.25080.5" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: src/Titan.Host/Program.cs
// ============================================
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Domain.Interfaces;
using Titan.Infrastructure.Cache;
using Titan.Infrastructure.Hardware.Scale;
using Titan.Infrastructure.Hardware.Printer;
using Titan.Infrastructure.Messaging;
using Titan.Infrastructure.Persistence;
using Titan.Infrastructure.Persistence.Repositories;
using Titan.Infrastructure.Services;
using Titan.TUI.Services;

namespace Titan.Host;

public class Program
{
    public static async Task Main(string[] args)
    {
        var builder = Host.CreateApplicationBuilder(args);

        // Configuration
        builder.Configuration.AddEnvironmentVariables(prefix: "TITAN_");
        builder.Configuration.AddCommandLine(args);

        // Logging
        builder.Logging.SetMinimumLevel(LogLevel.Information);
        builder.Logging.AddConsole();

        // Database
        var connectionString = builder.Configuration.GetConnectionString("PostgreSQL") 
            ?? "Host=localhost;Database=titan;Username=titan;Password=titan";

        builder.Services.AddDbContext<TitanDbContext>(options =>
        {
            options.UseNpgsql(connectionString);
        });

        // Cache
        builder.Services.AddMemoryCache();
        builder.Services.AddSingleton<ICacheService, MemoryCacheService>();

        // Repositories
        builder.Services.AddScoped<IProductRepository, ProductRepository>();
        builder.Services.AddScoped<IBatchRepository, BatchRepository>();
        builder.Services.AddScoped<IWeightRecordRepository, WeightRecordRepository>();

        // Services
        builder.Services.AddSingleton<IEpcGenerator>(sp =>
        {
            var scope = sp.CreateScope();
            var context = scope.ServiceProvider.GetRequiredService<TitanDbContext>();
            return new EpcGenerator(context, "3034257BF7194E4");
        });

        builder.Services.AddSingleton<BatchProcessingService>();
        builder.Services.AddSingleton<IElixirBridgeClient, ElixirBridgeClient>();

        // Hardware
        builder.Services.AddSingleton<IScalePort, SerialScalePort>();
        builder.Services.AddSingleton<IPrinterTransport, DeviceFilePrinter>();

        // Hosted Services
        builder.Services.AddHostedService<ScaleReadingService>();
        builder.Services.AddHostedService<DataSyncService>();
        builder.Services.AddHostedService<TuiHostedService>();

        var host = builder.Build();

        // Ensure database is created
        using (var scope = host.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<TitanDbContext>();
            await db.Database.MigrateAsync();
        }

        await host.RunAsync();
    }
}

// ============================================
// File: src/Titan.Host/Services/ScaleReadingService.cs
// ============================================
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Infrastructure.Hardware.Scale;

namespace Titan.Host.Services;

public class ScaleReadingService : IHostedService
{
    private readonly ILogger<ScaleReadingService> _logger;
    private readonly IScalePort _scalePort;
    private readonly BatchProcessingService _batchService;
    private readonly IConfiguration _configuration;
    private CancellationTokenSource? _cts;
    private Task? _readingTask;

    public ScaleReadingService(
        ILogger<ScaleReadingService> logger,
        IScalePort scalePort,
        BatchProcessingService batchService,
        IConfiguration configuration)
    {
        _logger = logger;
        _scalePort = scalePort;
        _batchService = batchService;
        _configuration = configuration;
    }

    public async Task StartAsync(CancellationToken ct)
    {
        var portName = _configuration.GetValue<string>("Hardware:ScalePort") ?? "/dev/ttyUSB0";
        var baudRate = _configuration.GetValue<int>("Hardware:ScaleBaudRate", 9600);

        _logger.LogInformation("Connecting to scale on {Port}...", portName);
        
        if (await _scalePort.ConnectAsync(portName, baudRate, ct))
        {
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _readingTask = ReadScaleAsync(_cts.Token);
            _logger.LogInformation("Scale connected successfully");
        }
        else
        {
            _logger.LogWarning("Failed to connect to scale. Retrying in background...");
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _readingTask = RetryConnectionAsync(portName, baudRate, _cts.Token);
        }
    }

    public async Task StopAsync(CancellationToken ct)
    {
        _cts?.Cancel();
        
        if (_readingTask != null)
        {
            try
            {
                await _readingTask.WaitAsync(TimeSpan.FromSeconds(5), ct);
            }
            catch { }
        }
        
        await _scalePort.DisconnectAsync(ct);
    }

    private async Task ReadScaleAsync(CancellationToken ct)
    {
        try
        {
            await foreach (var reading in _scalePort.ReadAsync(ct))
            {
                _batchService.ProcessWeight(reading.Value, reading.Unit);
                _logger.LogDebug("Weight: {Value} {Unit} (Stable: {Stable})", 
                    reading.Value, reading.Unit, reading.IsStable);
            }
        }
        catch (OperationCanceledException)
        {
            // Normal cancellation
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error reading from scale");
        }
    }

    private async Task RetryConnectionAsync(string portName, int baudRate, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
                
                if (await _scalePort.ConnectAsync(portName, baudRate, ct))
                {
                    await ReadScaleAsync(ct);
                    break;
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Retry connection failed");
            }
        }
    }
}

// ============================================
// File: src/Titan.Host/Services/DataSyncService.cs
// ============================================
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Domain.Interfaces;
using Titan.Infrastructure.Messaging;

namespace Titan.Host.Services;

public class DataSyncService : IHostedService
{
    private readonly ILogger<DataSyncService> _logger;
    private readonly IWeightRecordRepository _weightRepository;
    private readonly IElixirBridgeClient _elixirClient;
    private readonly IConfiguration _configuration;
    private Timer? _syncTimer;

    public DataSyncService(
        ILogger<DataSyncService> logger,
        IWeightRecordRepository weightRepository,
        IElixirBridgeClient elixirClient,
        IConfiguration configuration)
    {
        _logger = logger;
        _weightRepository = weightRepository;
        _elixirClient = elixirClient;
        _configuration = configuration;
    }

    public Task StartAsync(CancellationToken ct)
    {
        var elixirUrl = _configuration.GetValue<string>("Elixir:Url");
        var apiToken = _configuration.GetValue<string>("Elixir:ApiToken");

        if (!string.IsNullOrEmpty(elixirUrl) && !string.IsNullOrEmpty(apiToken))
        {
            _elixirClient.ConnectAsync(elixirUrl, apiToken).Wait(ct);
            
            // Sync every 30 seconds
            _syncTimer = new Timer(SyncDataAsync, null, TimeSpan.Zero, TimeSpan.FromSeconds(30));
            _logger.LogInformation("Data sync service started");
        }
        else
        {
            _logger.LogWarning("Elixir not configured. Running in offline mode.");
        }

        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct)
    {
        _syncTimer?.Change(Timeout.Infinite, 0);
        _syncTimer?.Dispose();
        return Task.CompletedTask;
    }

    private async void SyncDataAsync(object? state)
    {
        try
        {
            var unsyncedRecords = await _weightRepository.GetUnsyncedAsync();
            
            if (unsyncedRecords.Count == 0)
                return;

            _logger.LogInformation("Syncing {Count} records to ERP...", unsyncedRecords.Count);

            var syncData = unsyncedRecords.Select(r => new
            {
                r.Id,
                r.BatchId,
                r.ProductId,
                r.Weight,
                r.Unit,
                r.EpcCode,
                r.RecordedAt
            });

            if (await _elixirClient.SyncWeightRecordsAsync(syncData))
            {
                foreach (var record in unsyncedRecords)
                {
                    await _weightRepository.MarkAsSyncedAsync(record.Id);
                }
                
                _logger.LogInformation("Successfully synced {Count} records", unsyncedRecords.Count);
            }
            else
            {
                _logger.LogWarning("Failed to sync records. Will retry later.");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error during data sync");
        }
    }
}

// ============================================
// File: src/Titan.Host/appsettings.json
/*
{
  "ConnectionStrings": {
    "PostgreSQL": "Host=localhost;Database=titan;Username=titan;Password=titan"
  },
  "Hardware": {
    "ScalePort": "/dev/ttyUSB0",
    "ScaleBaudRate": 9600,
    "PrinterDevice": "/dev/usb/lp0"
  },
  "Elixir": {
    "Url": "http://localhost:4000",
    "ApiToken": ""
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  }
}
*/
