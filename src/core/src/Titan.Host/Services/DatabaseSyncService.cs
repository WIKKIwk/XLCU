using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Domain.Entities;
using Titan.Domain.Interfaces;

namespace Titan.Host.Services;

/// <summary>
/// Har 5 daqiqada JSON fayldan yozilgan recordlarni PostgreSQL ga sinxronlaydi.
/// Hot path ni bloklamaydi — faqat background da ishlaydi.
/// </summary>
public class DatabaseSyncService : BackgroundService
{
    private readonly JsonFileRecordStore _recordStore;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<DatabaseSyncService> _logger;
    private readonly TimeSpan _syncInterval = TimeSpan.FromMinutes(5);

    public DatabaseSyncService(
        JsonFileRecordStore recordStore,
        IServiceScopeFactory scopeFactory,
        ILogger<DatabaseSyncService> logger)
    {
        _recordStore = recordStore;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _logger.LogInformation("DatabaseSyncService started — syncing every {Interval} minutes",
            _syncInterval.TotalMinutes);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(_syncInterval, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            await SyncAsync(ct);
        }

        // Dastur to'xtashidan oldin oxirgi sync
        await SyncAsync(CancellationToken.None);
    }

    private async Task SyncAsync(CancellationToken ct)
    {
        try
        {
            var records = _recordStore.TakeAllPending();
            if (records.Count == 0) return;

            _logger.LogInformation("Syncing {Count} records to PostgreSQL...", records.Count);

            using var scope = _scopeFactory.CreateScope();
            var repo = scope.ServiceProvider.GetRequiredService<IWeightRecordRepository>();

            int synced = 0;
            foreach (var entry in records)
            {
                if (ct.IsCancellationRequested) break;

                try
                {
                    var record = new WeightRecord(
                        entry.BatchId, entry.ProductId, entry.Weight, entry.Unit, entry.EpcCode);
                    await repo.AddAsync(record);
                    synced++;
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex,
                        "Failed to sync record {Epc} — will retry next cycle", entry.EpcCode);
                }
            }

            _logger.LogInformation("Synced {Synced}/{Total} records to PostgreSQL",
                synced, records.Count);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Database sync failed — will retry in {Interval} minutes",
                _syncInterval.TotalMinutes);
        }
    }
}
