using System.Threading.Channels;
using Microsoft.Extensions.Logging;
using Titan.Domain.Events;

namespace Titan.Core.Fsm;

public sealed class BatchProcessingFsm
{
    private readonly Channel<DomainEvent> _eventChannel;
    private readonly StabilityDetector _stabilityDetector;
    private readonly FsmConfiguration _config;
    private readonly ILogger? _logger;
    private readonly object _lock = new();

    public BatchProcessingState State { get; private set; } = BatchProcessingState.Idle;
    public PauseReason PauseReason { get; private set; } = PauseReason.None;

    public string? ActiveBatchId { get; private set; }
    public string? ActiveProductId { get; private set; }
    public double? LockedWeight { get; private set; }

    private double _lastPrintedWeight;
    private bool _waitingForChange;
    private double _stateEnteredAt;

    public BatchProcessingFsm(
        Channel<DomainEvent> eventChannel,
        StabilityDetector stabilityDetector,
        FsmConfiguration? config = null,
        ILogger? logger = null)
    {
        _eventChannel = eventChannel;
        _stabilityDetector = stabilityDetector;
        _config = config ?? FsmConfiguration.Default;
        _logger = logger;
    }

    public void StartBatch(string batchId, string productId, double placementMinWeight)
    {
        lock (_lock)
        {
            ActiveBatchId = batchId;
            ActiveProductId = productId;
            _stabilityDetector.Reset();
            _stabilityDetector.SetPlacementMinWeight(placementMinWeight);
            _lastPrintedWeight = 0;
            _waitingForChange = false;

            TransitionTo(BatchProcessingState.WaitEmpty);
            _eventChannel.Writer.TryWrite(new BatchStartedEvent(batchId));
        }
    }

    public void StopBatch()
    {
        lock (_lock)
        {
            if (ActiveBatchId != null)
                _eventChannel.Writer.TryWrite(new BatchCompletedEvent(ActiveBatchId));

            PauseReason = PauseReason.BatchStopped;
            TransitionTo(BatchProcessingState.Paused);
        }
    }

    public void ChangeProduct(string productId)
    {
        lock (_lock)
        {
            ActiveProductId = productId;
            if (ActiveBatchId != null)
                _eventChannel.Writer.TryWrite(new ProductChangedEvent(ActiveBatchId, productId));
        }
    }

    public void ProcessWeightSample(WeightSample sample)
    {
        lock (_lock)
        {
            if (State == BatchProcessingState.Idle || State == BatchProcessingState.Paused)
                return;

            switch (State)
            {
                case BatchProcessingState.WaitEmpty:
                    if (sample.Value >= _stabilityDetector.PlacementMinWeight)
                    {
                        _stabilityDetector.Reset();
                        _logger?.LogDebug("FSM: WaitEmpty → Settling (weight={Weight:F3})", sample.Value);
                        TransitionTo(BatchProcessingState.Settling);
                    }
                    break;

                case BatchProcessingState.Settling:
                    _stabilityDetector.AddSample(sample);
                    HandleSettling(sample);
                    break;

                case BatchProcessingState.Locked:
                    break;
            }
        }
    }

    private void HandleSettling(WeightSample sample)
    {
        if (sample.Value < _config.EmptyThreshold)
        {
            _lastPrintedWeight = 0;
            _waitingForChange = false;
            _stabilityDetector.Reset();
            _logger?.LogDebug("FSM: Settling → WaitEmpty (weight=0, reset)");
            TransitionTo(BatchProcessingState.WaitEmpty);
            return;
        }

        if (_waitingForChange)
        {
            var diff = Math.Abs(sample.Value - _lastPrintedWeight);
            var threshold = CalculateChangeLimit(_lastPrintedWeight);

            if (diff > threshold)
            {
                _waitingForChange = false;
                _stabilityDetector.Reset();
                _stabilityDetector.AddSample(sample);
                _logger?.LogInformation(
                    "FSM: Change detected! value={Value:F3}, lastPrint={Last:F3}, diff={Diff:F3} > threshold={Thr:F3}",
                    sample.Value, _lastPrintedWeight, diff, threshold);
            }
            return;
        }

        if (_stabilityDetector.IsStable)
        {
            var currentMean = _stabilityDetector.Mean;
            var diff = Math.Abs(currentMean - _lastPrintedWeight);
            var threshold = CalculateChangeLimit(_lastPrintedWeight);

            _logger?.LogDebug(
                "FSM: Stable! mean={Mean:F3}, lastPrint={Last:F3}, diff={Diff:F3}, threshold={Thr:F3}, samples={N}",
                currentMean, _lastPrintedWeight, diff, threshold, _stabilityDetector.TotalSamples);

            if (diff > threshold)
            {
                LockedWeight = currentMean;
                _logger?.LogInformation("FSM: Settling → Locked (weight={Weight:F3} kg)", currentMean);
                TransitionTo(BatchProcessingState.Locked);
                EmitWeightStabilized();
            }
        }
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
        lock (_lock)
        {
            if (State != BatchProcessingState.Locked) return;

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
        lock (_lock)
        {
            if (State != BatchProcessingState.Locked) return;

            _lastPrintedWeight = LockedWeight ?? 0;
            _waitingForChange = true;
            _stabilityDetector.Reset();

            _logger?.LogInformation(
                "FSM: Locked → Settling (printed={Printed:F3}, waiting for change)",
                _lastPrintedWeight);
            TransitionTo(BatchProcessingState.Settling);
        }
    }

    /// <summary>
    /// Immediately transitions Locked → Settling so new weight samples can be processed.
    /// Call this BEFORE any slow async I/O (EPC generation, printing, DB save).
    /// </summary>
    public void AcknowledgePrint()
    {
        lock (_lock)
        {
            if (State != BatchProcessingState.Locked) return;

            _lastPrintedWeight = LockedWeight ?? 0;
            _waitingForChange = true;
            _stabilityDetector.Reset();

            _logger?.LogInformation(
                "FSM: Locked → Settling (weight={Weight:F3}, waiting for change)",
                _lastPrintedWeight);
            TransitionTo(BatchProcessingState.Settling);
        }
    }

    private void TransitionTo(BatchProcessingState newState, double? timestamp = null)
    {
        State = newState;
        _stateEnteredAt = timestamp ?? GetTimestamp();
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
