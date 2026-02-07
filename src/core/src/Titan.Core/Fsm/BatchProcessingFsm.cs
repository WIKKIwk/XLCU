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
