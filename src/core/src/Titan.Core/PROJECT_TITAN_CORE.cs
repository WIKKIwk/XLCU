// ============================================
// TITAN.CORE - Business Logic Layer
// ============================================
// File: src/Titan.Core/Titan.Core.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Titan.Core</RootNamespace>
    <LangVersion>14.0</LangVersion>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../Titan.Domain/Titan.Domain.csproj" />
  </ItemGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Extensions.Caching.Memory" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Microsoft.Extensions.Logging.Abstractions" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="System.Threading.Channels" Version="10.0.0-preview.1.25080.5" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: src/Titan.Core/Fsm/BatchProcessingState.cs
// ============================================
namespace Titan.Core.Fsm;

public enum BatchProcessingState
{
    Idle,
    WaitEmpty,
    Loading,
    Settling,
    Locked,
    Printing,
    PostGuard,
    Paused
}

public enum PauseReason
{
    None,
    Manual,
    ReweighRequired,
    PrinterError,
    BatchStopped
}

// ============================================
// File: src/Titan.Core/Fsm/BatchProcessingFsm.cs
// ============================================
using System.Threading.Channels;
using Titan.Domain.Events;

namespace Titan.Core.Fsm;

public sealed class BatchProcessingFsm
{
    private readonly Channel<DomainEvent> _eventChannel;
    private readonly StabilityDetector _stabilityDetector;
    private readonly FsmConfiguration _config;

    public BatchProcessingState State { get; private set; } = BatchProcessingState.Idle;
    public PauseReason PauseReason { get; private set; } = PauseReason.None;
    
    public string? ActiveBatchId { get; private set; }
    public string? ActiveProductId { get; private set; }
    public double? LockedWeight { get; private set; }
    
    private double _stateEnteredAt;
    private double? _belowEmptySince;
    private bool _printRequested;
    private string? _currentEventId;

    public BatchProcessingFsm(
        Channel<DomainEvent> eventChannel,
        StabilityDetector stabilityDetector,
        FsmConfiguration? config = null)
    {
        _eventChannel = eventChannel;
        _stabilityDetector = stabilityDetector;
        _config = config ?? FsmConfiguration.Default;
    }

    public void StartBatch(string batchId, string productId, double placementMinWeight)
    {
        ActiveBatchId = batchId;
        ActiveProductId = productId;
        _stabilityDetector.Reset();
        _stabilityDetector.SetPlacementMinWeight(placementMinWeight);
        
        TransitionTo(BatchProcessingState.WaitEmpty);
        _eventChannel.Writer.TryWrite(new BatchStartedEvent(batchId));
    }

    public void StopBatch()
    {
        if (ActiveBatchId != null)
        {
            _eventChannel.Writer.TryWrite(new BatchCompletedEvent(ActiveBatchId));
        }
        
        PauseReason = PauseReason.BatchStopped;
        TransitionTo(BatchProcessingState.Paused);
    }

    public void ChangeProduct(string productId)
    {
        if (State == BatchProcessingState.WaitEmpty)
        {
            ActiveProductId = productId;
            if (ActiveBatchId != null)
            {
                _eventChannel.Writer.TryWrite(new ProductChangedEvent(ActiveBatchId, productId));
            }
        }
    }

    public void ProcessWeightSample(WeightSample sample)
    {
        UpdateEmptyStatus(sample.Value, sample.Timestamp);

        if (State == BatchProcessingState.Paused)
        {
            HandlePausedState(sample);
            return;
        }

        _stabilityDetector.AddSample(sample);

        switch (State)
        {
            case BatchProcessingState.WaitEmpty:
                HandleWaitEmpty(sample);
                break;
            case BatchProcessingState.Loading:
                HandleLoading(sample);
                break;
            case BatchProcessingState.Settling:
                HandleSettling(sample);
                break;
            case BatchProcessingState.Locked:
                HandleLocked(sample);
                break;
            case BatchProcessingState.Printing:
                HandlePrinting(sample);
                break;
            case BatchProcessingState.PostGuard:
                HandlePostGuard(sample);
                break;
        }
    }

    private void HandleWaitEmpty(WeightSample sample)
    {
        if (sample.Value >= _stabilityDetector.PlacementMinWeight)
        {
            _stabilityDetector.Reset();
            _printRequested = false;
            TransitionTo(BatchProcessingState.Loading);
        }
    }

    private void HandleLoading(WeightSample sample)
    {
        if (IsBelowEmptyForClear(sample.Timestamp))
        {
            _stabilityDetector.Reset();
            TransitionTo(BatchProcessingState.WaitEmpty);
            return;
        }

        if (sample.Timestamp - _stateEnteredAt >= _config.SettleSeconds
            && _stabilityDetector.TotalSamples >= _config.MinSamples)
        {
            TransitionTo(BatchProcessingState.Settling);
        }
    }

    private void HandleSettling(WeightSample sample)
    {
        if (IsBelowEmptyForClear(sample.Timestamp))
        {
            _stabilityDetector.Reset();
            TransitionTo(BatchProcessingState.WaitEmpty);
            return;
        }

        if (_stabilityDetector.IsStable)
        {
            LockAndRequestPrint(sample.Timestamp);
        }
    }

    private void HandleLocked(WeightSample sample)
    {
        var changeLimit = CalculateChangeLimit(LockedWeight ?? 0);
        
        if (Math.Abs(sample.Value - (LockedWeight ?? 0)) > changeLimit)
        {
            if (_printRequested)
            {
                PauseReason = PauseReason.ReweighRequired;
                TransitionTo(BatchProcessingState.Paused);
            }
            else
            {
                _stabilityDetector.Reset();
                _printRequested = false;
                TransitionTo(BatchProcessingState.Settling);
            }
            return;
        }

        if (!_printRequested)
        {
            _printRequested = true;
            _currentEventId = Guid.NewGuid().ToString("N");
            EmitWeightStabilized();
        }
    }

    private void HandlePrinting(WeightSample sample)
    {
        var changeLimit = CalculateChangeLimit(LockedWeight ?? 0);
        if (Math.Abs(sample.Value - (LockedWeight ?? 0)) > changeLimit)
        {
            PauseReason = PauseReason.ReweighRequired;
            TransitionTo(BatchProcessingState.Paused);
        }
    }

    private void HandlePostGuard(WeightSample sample)
    {
        if (IsBelowEmptyForClear(sample.Timestamp))
        {
            TransitionTo(BatchProcessingState.WaitEmpty);
        }
    }

    private void HandlePausedState(WeightSample sample)
    {
        if (PauseReason == PauseReason.ReweighRequired || PauseReason == PauseReason.BatchStopped)
        {
            if (IsBelowEmptyForClear(sample.Timestamp))
            {
                PauseReason = PauseReason.None;
                TransitionTo(BatchProcessingState.WaitEmpty);
            }
        }
    }

    private void LockAndRequestPrint(double timestamp)
    {
        if (ActiveBatchId == null || ActiveProductId == null)
            return;

        LockedWeight = _stabilityDetector.Mean;
        _currentEventId = Guid.NewGuid().ToString("N");
        _printRequested = true;
        
        TransitionTo(BatchProcessingState.Locked, timestamp);
        EmitWeightStabilized();
    }

    private void EmitWeightStabilized()
    {
        if (ActiveBatchId != null && ActiveProductId != null && LockedWeight.HasValue)
        {
            _eventChannel.Writer.TryWrite(new WeightStabilizedEvent(
                ActiveBatchId,
                ActiveProductId,
                LockedWeight.Value,
                "kg"));
        }
    }

    public void ConfirmPrintSent(string epcCode)
    {
        if (State == BatchProcessingState.Locked && _printRequested)
        {
            TransitionTo(BatchProcessingState.Printing);
            
            if (ActiveBatchId != null && ActiveProductId != null && LockedWeight.HasValue)
            {
                _eventChannel.Writer.TryWrite(new LabelPrintedEvent(
                    ActiveBatchId,
                    ActiveProductId,
                    epcCode,
                    LockedWeight.Value));
            }
        }
    }

    public void ConfirmPrintCompleted()
    {
        if (State == BatchProcessingState.Printing)
        {
            TransitionTo(BatchProcessingState.PostGuard);
        }
    }

    private void TransitionTo(BatchProcessingState newState, double? timestamp = null)
    {
        State = newState;
        _stateEnteredAt = timestamp ?? GetTimestamp();
    }

    private void UpdateEmptyStatus(double weight, double now)
    {
        if (weight < _config.EmptyThreshold)
        {
            _belowEmptySince ??= now;
        }
        else
        {
            _belowEmptySince = null;
        }
    }

    private bool IsBelowEmptyForClear(double now)
    {
        return _belowEmptySince.HasValue && (now - _belowEmptySince.Value) >= _config.ClearSeconds;
    }

    private double CalculateChangeLimit(double weight)
    {
        return Math.Max(_config.Eps, weight * _config.EpsAlign);
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}

// ============================================
// File: src/Titan.Core/Fsm/StabilityDetector.cs
// ============================================
namespace Titan.Core.Fsm;

public sealed class StabilityDetector
{
    private readonly Queue<WeightSample> _samples = new();
    private readonly StabilityConfiguration _config;

    public double Mean { get; private set; }
    public double StdDev { get; private set; }
    public bool IsStable { get; private set; }
    public int TotalSamples => _samples.Count;
    public double PlacementMinWeight { get; private set; } = 1.0;

    public StabilityDetector(StabilityConfiguration? config = null)
    {
        _config = config ?? StabilityConfiguration.Default;
    }

    public void SetPlacementMinWeight(double value) => PlacementMinWeight = value;

    public void AddSample(WeightSample sample)
    {
        _samples.Enqueue(sample);
        
        // Remove old samples outside window
        while (_samples.Count > 0)
        {
            var oldest = _samples.Peek();
            if (sample.Timestamp - oldest.Timestamp > _config.WindowSeconds)
                _samples.Dequeue();
            else
                break;
        }

        CalculateStatistics();
        CheckStability();
    }

    public void Reset()
    {
        _samples.Clear();
        Mean = 0;
        StdDev = 0;
        IsStable = false;
    }

    private void CalculateStatistics()
    {
        if (_samples.Count == 0) return;

        var values = _samples.Select(s => s.Value).ToList();
        Mean = values.Average();
        
        if (values.Count > 1)
        {
            var variance = values.Select(v => (v - Mean) * (v - Mean)).Average();
            StdDev = Math.Sqrt(variance);
        }
        else
        {
            StdDev = 0;
        }
    }

    private void CheckStability()
    {
        if (_samples.Count < _config.MinSamples)
        {
            IsStable = false;
            return;
        }

        // Check if all samples are within tolerance
        var values = _samples.Select(s => s.Value).ToList();
        var maxChange = values.Max() - values.Min();
        
        IsStable = maxChange <= _config.Eps && StdDev <= _config.Sigma;
    }
}

// ============================================
// File: src/Titan.Core/Fsm/Configuration.cs
// ============================================
namespace Titan.Core.Fsm;

public sealed record WeightSample(
    double Value,
    string Unit,
    double Timestamp
);

public sealed record FsmConfiguration(
    double SettleSeconds,
    double ClearSeconds,
    int MinSamples,
    double EmptyThreshold
)
{
    public static FsmConfiguration Default => new(
        SettleSeconds: 0.50,
        ClearSeconds: 0.70,
        MinSamples: 10,
        EmptyThreshold: 0.05
    );
}

public sealed record StabilityConfiguration(
    double Sigma,
    double Eps,
    double EpsAlign,
    double WindowSeconds,
    int MinSamples
)
{
    public static StabilityConfiguration Default => new(
        Sigma: 0.01,
        Eps: 0.03,
        EpsAlign: 0.06,
        WindowSeconds: 1.0,
        MinSamples: 10
    );
}

// ============================================
// File: src/Titan.Core/Services/BatchProcessingService.cs
// ============================================
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
        
        // Update cache
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

// ============================================
// File: src/Titan.Core/Services/IEpcGenerator.cs
// ============================================
namespace Titan.Core.Services;

public interface IEpcGenerator
{
    Task<string> GenerateNextAsync();
    Task<long> GetCurrentCounterAsync();
}
