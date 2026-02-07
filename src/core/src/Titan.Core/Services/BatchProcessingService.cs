using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Titan.Domain.Entities;
using Titan.Domain.Events;
using Titan.Domain.Interfaces;
using Titan.Core.Fsm;

namespace Titan.Core.Services;

public sealed class BatchProcessingService : IDisposable
{
    private readonly BatchProcessingFsm _fsm;
    private readonly Channel<DomainEvent> _eventChannel;
    private readonly IWeightRecordRepository _weightRepository;
    private readonly IProductRepository _productRepository;
    private readonly ICacheService _cache;
    private readonly IEpcGenerator _epcGenerator;
    private readonly ILogger<BatchProcessingService> _logger;
    private readonly CancellationTokenSource _cts = new();

    public BatchProcessingService(
        IWeightRecordRepository weightRepository,
        IProductRepository productRepository,
        ICacheService cache,
        IEpcGenerator epcGenerator,
        ILogger<BatchProcessingService> logger)
    {
        _eventChannel = Channel.CreateUnbounded<DomainEvent>();
        _fsm = new BatchProcessingFsm(_eventChannel, new StabilityDetector());
        _weightRepository = weightRepository;
        _productRepository = productRepository;
        _cache = cache;
        _epcGenerator = epcGenerator;
        _logger = logger;

        _ = ProcessEventsAsync(_cts.Token);
    }

    public void StartBatch(string batchId, string productId, double placementMinWeight = 1.0)
    {
        _fsm.StartBatch(batchId, productId, placementMinWeight);
        _logger.LogInformation("Batch started: {BatchId}, Product: {ProductId}", batchId, productId);
    }

    public void StopBatch()
    {
        _fsm.StopBatch();
        _logger.LogInformation("Batch stopped");
    }

    public void ChangeProduct(string productId)
    {
        _fsm.ChangeProduct(productId);
        _logger.LogInformation("Product changed to: {ProductId}", productId);
    }

    public void ProcessWeight(double value, string unit)
    {
        var timestamp = (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
        _fsm.ProcessWeightSample(new WeightSample(value, unit, timestamp));
    }

    public async Task ConfirmPrintAsync(string? epcCode = null)
    {
        var actualEpc = epcCode ?? await _epcGenerator.GenerateNextAsync();
        _fsm.ConfirmPrintSent(actualEpc);
        _logger.LogInformation("Print confirmed with EPC: {Epc}", actualEpc);
    }

    public void CompletePrint()
    {
        _fsm.ConfirmPrintCompleted();
    }

    public BatchProcessingState CurrentState => _fsm.State;
    public string? ActiveBatchId => _fsm.ActiveBatchId;
    public string? ActiveProductId => _fsm.ActiveProductId;
    public double? CurrentWeight => _fsm.LockedWeight;

    private async Task ProcessEventsAsync(CancellationToken ct)
    {
        await foreach (var evt in _eventChannel.Reader.ReadAllAsync(ct))
        {
            try
            {
                switch (evt)
                {
                    case WeightStabilizedEvent e:
                        _logger.LogInformation("Weight stabilized: {Weight} kg", e.Weight);
                        break;
                    case LabelPrintedEvent e:
                        await HandleLabelPrintedAsync(e);
                        break;
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error processing event: {EventType}", evt.GetType().Name);
            }
        }
    }

    private async Task HandleLabelPrintedAsync(LabelPrintedEvent evt)
    {
        var record = new WeightRecord(
            evt.BatchId,
            evt.ProductId,
            evt.Weight,
            "kg",
            evt.EpcCode);

        await _weightRepository.AddAsync(record);

        var cacheKey = $"records:{evt.BatchId}";
        var records = await _cache.GetAsync<List<WeightRecord>>(cacheKey) ?? new List<WeightRecord>();
        records.Add(record);
        await _cache.SetAsync(cacheKey, records, TimeSpan.FromHours(24));

        _logger.LogInformation("Weight record saved: {Epc}", evt.EpcCode);
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }
}
