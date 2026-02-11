using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Titan.Domain.Events;
using Titan.Core.Fsm;

namespace Titan.Core.Services;

public sealed class BatchProcessingService : IDisposable
{
    private readonly BatchProcessingFsm _fsm;
    private readonly Channel<DomainEvent> _eventChannel;
    private readonly IEpcGenerator _epcGenerator;
    private readonly JsonFileRecordStore _recordStore;
    private readonly ILogger<BatchProcessingService> _logger;
    private readonly CancellationTokenSource _cts = new();

    private bool _batchActive;
    private int _printCount;

    /// <summary>
    /// Host layer bu callback ni o'rnatadi.
    /// Chaqiriladi: (weight, unit, epcCode, productId) => true/false
    /// </summary>
    public Func<double, string, string, string, Task<bool>>? OnPrintRequested { get; set; }

    public BatchProcessingService(
        IEpcGenerator epcGenerator,
        JsonFileRecordStore recordStore,
        ILogger<BatchProcessingService> logger)
    {
        _eventChannel = Channel.CreateUnbounded<DomainEvent>();
        _fsm = new BatchProcessingFsm(_eventChannel, new StabilityDetector(), logger: logger);
        _epcGenerator = epcGenerator;
        _recordStore = recordStore;
        _logger = logger;

        _ = ProcessEventsAsync(_cts.Token);
    }

    public void AutoStart(string productId = "default")
    {
        if (_batchActive) return;

        var batchId = $"auto-{DateTime.UtcNow:yyyyMMdd-HHmmss}";
        _fsm.StartBatch(batchId, productId, placementMinWeight: 0.1);
        _batchActive = true;
        _printCount = 0;
        _logger.LogInformation("=== Autonomous batch started: {BatchId} ===", batchId);
    }

    public void ProcessWeight(double value, string unit)
    {
        if (!_batchActive) return;

        var timestamp = (double)System.Diagnostics.Stopwatch.GetTimestamp()
                        / System.Diagnostics.Stopwatch.Frequency;
        _fsm.ProcessWeightSample(new WeightSample(value, unit, timestamp));
    }

    public BatchProcessingState CurrentState => _fsm.State;
    public string? ActiveBatchId => _fsm.ActiveBatchId;
    public string? ActiveProductId => _fsm.ActiveProductId;
    public double? CurrentWeight => _fsm.LockedWeight;
    public int PrintCount => _printCount;

    public void StartBatch(string batchId, string productId, double placementMinWeight = 1.0)
    {
        _fsm.StartBatch(batchId, productId, placementMinWeight);
        _batchActive = true;
        _printCount = 0;
        _logger.LogInformation("Batch started: {BatchId}, Product: {ProductId}", batchId, productId);
    }

    public void StopBatch()
    {
        _fsm.StopBatch();
        _batchActive = false;
        _logger.LogInformation("Batch stopped");
    }

    private async Task ProcessEventsAsync(CancellationToken ct)
    {
        await foreach (var evt in _eventChannel.Reader.ReadAllAsync(ct))
        {
            try
            {
                switch (evt)
                {
                    case WeightStabilizedEvent e:
                        _logger.LogInformation(
                            ">>> Weight STABLE: {Weight:F3} kg — printing...", e.Weight);
                        HandleStabilized(e);
                        break;

                    case BatchStartedEvent:
                        _logger.LogInformation("Batch started, waiting for product on scale...");
                        break;
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error processing event: {EventType}", evt.GetType().Name);
            }
        }
    }

    private void HandleStabilized(WeightStabilizedEvent evt)
    {
        // 1. FSM ni DARHOL oldinga surish — hech qanday async I/O yo'q
        _fsm.AcknowledgePrint();
        _printCount++;
        _logger.LogInformation(
            "<<< WEIGHT LOCKED #{Count}: {Weight:F3} kg — sending to printer...",
            _printCount, evt.Weight);

        // 2. EPC generatsiya — JSON fayldan, SINXRON, mikrosekundlarda
        var epcCode = _epcGenerator.GenerateNextAsync().GetAwaiter().GetResult();

        // 3. JSON faylga yozish — SINXRON, mikrosekundlarda
        _recordStore.Append(new WeightRecordEntry
        {
            BatchId = evt.BatchId,
            ProductId = evt.ProductId,
            Weight = evt.Weight,
            Unit = evt.Unit,
            EpcCode = epcCode,
            CreatedAt = DateTime.UtcNow
        });

        _logger.LogInformation(
            "<<< SAVED to JSON: {Weight:F3} kg, EPC: {Epc}", evt.Weight, epcCode);

        // 4. Printerga yuborish — background da (sekin bo'lishi mumkin)
        if (OnPrintRequested != null)
        {
            var callback = OnPrintRequested;
            var weight = evt.Weight;
            var unit = evt.Unit;
            var productId = evt.ProductId;

            _ = Task.Run(async () =>
            {
                try
                {
                    var success = await callback(weight, unit, epcCode, productId);
                    if (success)
                        _logger.LogInformation("<<< PRINTED: {Weight:F3} kg, EPC: {Epc}", weight, epcCode);
                    else
                        _logger.LogWarning("Print failed for {Weight:F3} kg (non-fatal)", weight);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Printer callback failed (non-fatal)");
                }
            });
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}
