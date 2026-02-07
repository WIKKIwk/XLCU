using Microsoft.Extensions.Configuration;
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
                r.Id, r.BatchId, r.ProductId, r.Weight, r.Unit, r.EpcCode, r.RecordedAt
            });

            if (await _elixirClient.SyncWeightRecordsAsync(syncData))
            {
                foreach (var record in unsyncedRecords)
                    await _weightRepository.MarkAsSyncedAsync(record.Id);

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
