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
    [InlineData(1.5, BatchProcessingState.Settling)]
    public void ProcessWeightSample_WaitEmpty_Should_TransitionCorrectly(double weight, BatchProcessingState expectedState)
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.ProcessWeightSample(new WeightSample(weight, "kg", GetTimestamp()));

        _fsm.State.Should().Be(expectedState);
    }

    [Fact]
    public void ProcessWeightSample_SettlingPhase_ShouldDetectStability()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        var baseTime = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", baseTime + i * 0.1));
        }

        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(2.0, 0.01);
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
    public void ChangeProduct_Should_UpdateProduct()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        _fsm.ChangeProduct("PROD-002");

        _fsm.ActiveProductId.Should().Be("PROD-002");
    }

    [Fact]
    public void PrintComplete_Should_TransitionTo_Settling()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }
        _fsm.State.Should().Be(BatchProcessingState.Locked);

        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();

        _fsm.State.Should().Be(BatchProcessingState.Settling);
    }

    [Fact]
    public void AcknowledgePrint_Should_TransitionTo_Settling()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }
        _fsm.State.Should().Be(BatchProcessingState.Locked);

        // AcknowledgePrint — bir qadamda Locked → Settling
        _fsm.AcknowledgePrint();

        _fsm.State.Should().Be(BatchProcessingState.Settling);
    }

    [Fact]
    public void AcknowledgePrint_Then_NewWeight_ShouldPrint()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);
        var timestamp = GetTimestamp();

        // Birinchi mahsulot: 9.0 kg
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(9.0, "kg", timestamp + i * 0.1));
        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(9.0, 0.01);

        // FSM ni darhol oldinga surish (async I/O boshlanishidan OLDIN)
        _fsm.AcknowledgePrint();
        _fsm.State.Should().Be(BatchProcessingState.Settling);

        // Ikkinchi mahsulot: 8.0 kg (o'zgarish 1.0 > threshold 0.54)
        var t2 = timestamp + 5.0;
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(8.0, "kg", t2 + i * 0.1));

        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(8.0, 0.01);
    }

    [Fact]
    public void AcknowledgePrint_MultipleWeightChanges_ShouldPrintEach()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);
        var timestamp = GetTimestamp();

        // 9 kg → print
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(9.0, "kg", timestamp + i * 0.1));
        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.AcknowledgePrint();

        // 8 kg → print
        var t2 = timestamp + 5.0;
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(8.0, "kg", t2 + i * 0.1));
        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.AcknowledgePrint();

        // 2 kg (0 orqali) → print
        var t3 = t2 + 5.0;
        _fsm.ProcessWeightSample(new WeightSample(0.0, "kg", t3));
        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);

        var t4 = t3 + 2.0;
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", t4 + i * 0.1));
        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(2.0, 0.01);
    }

    [Fact]
    public void ContinuousWeighing_ShouldPrint_WhenNewWeightStabilizes()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);
        var timestamp = GetTimestamp();

        // Birinchi mahsulot: 2.5 kg
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));

        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(2.5, 0.01);

        // Print tugadi
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();
        _fsm.State.Should().Be(BatchProcessingState.Settling);

        // Ikkinchi mahsulot ustiga qo'yildi: jami 5.0 kg
        // Avval o'ynaydi
        var t2 = timestamp + 5.0;
        _fsm.ProcessWeightSample(new WeightSample(4.0, "kg", t2));
        _fsm.ProcessWeightSample(new WeightSample(4.5, "kg", t2 + 0.1));
        _fsm.ProcessWeightSample(new WeightSample(5.2, "kg", t2 + 0.2));

        // Keyin 5.0 da qotadi
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(5.0, "kg", t2 + 1.0 + i * 0.1));

        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(5.0, 0.01);
    }

    [Fact]
    public void WeightDropToZero_ShouldReset()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);
        var timestamp = GetTimestamp();

        // Mahsulot qo'yildi va print qilindi
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();

        // Tarozi bo'shadi
        var t2 = timestamp + 5.0;
        _fsm.ProcessWeightSample(new WeightSample(0.0, "kg", t2));

        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);
    }

    [Fact]
    public void SameWeight_ShouldNotPrintTwice()
    {
        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);
        var timestamp = GetTimestamp();

        // Birinchi print
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        _fsm.State.Should().Be(BatchProcessingState.Locked);

        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();

        // Xuddi shu vaznda turadi — qayta print bo'lmasligi kerak
        var t2 = timestamp + 5.0;
        for (int i = 0; i < 15; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", t2 + i * 0.1));

        // Hali ham Settling da — Locked ga o'tmaydi
        _fsm.State.Should().Be(BatchProcessingState.Settling);
    }

    /// <summary>
    /// Fake scale simulyatorini aynan takrorlaydigan test:
    /// RAMP_RATE=3.0, TICK_SEC=0.05, RESET_TO_ZERO_ON_SET=true
    /// Senariy: set 9 → 6 sek → set 8 → 6 sek → set 2 → 6 sek → set 0
    /// </summary>
    [Fact]
    public void FakeScaleSimulation_9_8_2_0_ShouldPrintAll()
    {
        const double rampRate = 3.0;
        const double tickSec = 0.05;
        const double step = rampRate * tickSec; // 0.15 kg/tick

        _fsm.StartBatch("BATCH-001", "PROD-001", 0.1);

        var lockedWeights = new List<double>();
        var stateLog = new List<string>();
        double current = 0.0;
        double t = GetTimestamp();

        void SimulateRamp(double target, double durationSec)
        {
            // RESET_TO_ZERO_ON_SET: current goes to 0 first
            current = 0.0;

            int ticks = (int)(durationSec / tickSec);
            for (int i = 0; i < ticks; i++)
            {
                // Ramp toward target
                if (current < target)
                    current = Math.Min(target, current + step);
                else if (current > target)
                    current = Math.Max(target, current - step);

                t += tickSec;
                var prevState = _fsm.State;
                _fsm.ProcessWeightSample(new WeightSample(
                    Math.Round(current, 3), "kg", t));

                if (_fsm.State == BatchProcessingState.Locked && prevState != BatchProcessingState.Locked)
                {
                    lockedWeights.Add(_fsm.LockedWeight ?? 0);
                    stateLog.Add($"LOCKED at {_fsm.LockedWeight:F3} kg (t={t - GetTimestamp():F2}s)");
                    // Darhol AcknowledgePrint — real appda ham shunday
                    _fsm.AcknowledgePrint();
                }
            }
        }

        // set 9 → 6 sekund (ramp 0→9 = 3 sek, + 3 sek stable)
        SimulateRamp(9.0, 6.0);
        // set 8 → 6 sekund (reset to 0, ramp 0→8 = 2.67 sek, + 3.33 sek stable)
        SimulateRamp(8.0, 6.0);
        // set 2 → 6 sekund (reset to 0, ramp 0→2 = 0.67 sek, + 5.33 sek stable)
        SimulateRamp(2.0, 6.0);
        // set 0 → 2 sekund
        SimulateRamp(0.0, 2.0);

        // BARCHASI print bo'lishi kerak: 9, 8, 2
        lockedWeights.Should().HaveCount(3,
            $"Expected 3 prints (9, 8, 2) but got {lockedWeights.Count}: [{string.Join(", ", lockedWeights.Select(w => w.ToString("F3")))}]");
        lockedWeights[0].Should().BeApproximately(9.0, 0.1, "First print should be ~9 kg");
        lockedWeights[1].Should().BeApproximately(8.0, 0.1, "Second print should be ~8 kg");
        lockedWeights[2].Should().BeApproximately(2.0, 0.1, "Third print should be ~2 kg");
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}
