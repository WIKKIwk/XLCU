using Xunit;
using FluentAssertions;
using System.Threading.Channels;
using Titan.Domain.Events;
using Titan.Core.Fsm;

namespace Titan.Core.Tests.Fsm;

public class BatchProcessingFsmTests
{
    private readonly Channel<DomainEvent> _eventChannel;
    private readonly StabilityDetector _stabilityDetector;
    private readonly BatchProcessingFsm _fsm;

    public BatchProcessingFsmTests()
    {
        _eventChannel = Channel.CreateUnbounded<DomainEvent>();
        _stabilityDetector = new StabilityDetector();
        _fsm = new BatchProcessingFsm(_eventChannel, _stabilityDetector);
    }

    [Fact]
    public void Initial_State_ShouldBe_Idle()
    {
        _fsm.State.Should().Be(BatchProcessingState.Idle);
        _fsm.PauseReason.Should().Be(PauseReason.None);
    }

    [Fact]
    public void StartBatch_Should_TransitionTo_WaitEmpty()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);
        _fsm.ActiveBatchId.Should().Be("BATCH-001");
        _fsm.ActiveProductId.Should().Be("PROD-001");
    }

    [Fact]
    public void StartBatch_Should_ResetStabilityDetector()
    {
        _stabilityDetector.SetPlacementMinWeight(5.0);

        _fsm.StartBatch("BATCH-001", "PROD-001", 2.5);

        _stabilityDetector.PlacementMinWeight.Should().Be(2.5);
    }

    [Theory]
    [InlineData(0.0, BatchProcessingState.WaitEmpty)]
    [InlineData(1.5, BatchProcessingState.Loading)]
    public void ProcessWeightSample_WaitEmpty_Should_TransitionCorrectly(double weight, BatchProcessingState expectedState)
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.ProcessWeightSample(new WeightSample(weight, "kg", GetTimestamp()));

        _fsm.State.Should().Be(expectedState);
    }

    [Fact]
    public void ProcessWeightSample_SettingPhase_ShouldDetectStability()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        var baseTime = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", baseTime + i * 0.1));
        }

        _fsm.State.Should().Be(BatchProcessingState.Settling);
    }

    [Fact]
    public void StopBatch_Should_TransitionTo_Paused()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.StopBatch();

        _fsm.State.Should().Be(BatchProcessingState.Paused);
        _fsm.PauseReason.Should().Be(PauseReason.BatchStopped);
    }

    [Fact]
    public void WeightChange_AfterLock_Should_TriggerReweighRequired()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }

        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(2.5, 0.1);

        _fsm.ProcessWeightSample(new WeightSample(3.5, "kg", timestamp + 5.0));

        _fsm.State.Should().Be(BatchProcessingState.Paused);
        _fsm.PauseReason.Should().Be(PauseReason.ReweighRequired);
    }

    [Fact]
    public void ChangeProduct_InWaitEmpty_Should_UpdateProduct()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.ChangeProduct("PROD-002");

        _fsm.ActiveProductId.Should().Be("PROD-002");
    }

    [Fact]
    public void ChangeProduct_NotInWaitEmpty_Should_NotUpdateProduct()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", GetTimestamp()));

        _fsm.ChangeProduct("PROD-002");

        _fsm.ActiveProductId.Should().Be("PROD-001");
    }

    [Fact]
    public void PrintComplete_Should_TransitionTo_PostGuard()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.State.Should().Be(BatchProcessingState.Printing);

        _fsm.ConfirmPrintCompleted();

        _fsm.State.Should().Be(BatchProcessingState.PostGuard);
    }

    [Fact]
    public void WeightBelowEmpty_InPostGuard_Should_TransitionTo_WaitEmpty()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();

        for (int i = 0; i < 20; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();

        _fsm.State.Should().Be(BatchProcessingState.PostGuard);

        var newTime = timestamp + 10.0;
        for (int i = 0; i < 10; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(0.0, "kg", newTime + i * 0.1));
        }

        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}
