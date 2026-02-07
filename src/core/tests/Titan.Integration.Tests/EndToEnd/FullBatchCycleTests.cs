using Xunit;
using FluentAssertions;
using Titan.Core.Services;
using Titan.Core.Fsm;
using Titan.Integration.Tests.Simulation;

namespace Titan.Integration.Tests.EndToEnd;

public class FullBatchCycleTests
{
    [Fact]
    public async Task FullBatchCycle_CompleteScenario_Should_ProcessCorrectly()
    {
        var simulator = new WeightStreamSimulator();

        simulator.AddStablePhase(0.0, 2.0);
        simulator.AddRamp(0.0, 2.5, 3.0);
        simulator.AddStablePhase(2.5, 2.0);
        simulator.AddStablePhase(2.5, 1.0);
        simulator.AddRamp(2.5, 0.0, 1.0);
        simulator.AddStablePhase(0.0, 1.0);

        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var samplesProcessed = 0;

        await foreach (var sample in simulator.StreamAsync(cts.Token))
        {
            samplesProcessed++;
        }

        samplesProcessed.Should().BeGreaterThan(0);
    }

    [Fact]
    public void BatchCycle_WeightFluctuationAfterLock_Should_TriggerReweigh()
    {
        var simulator = new WeightStreamSimulator();

        simulator.AddStablePhase(2.5, 5.0, 0.05);
        simulator.AddRamp(2.5, 3.5, 0.5);

        var fsm = CreateFsm();
        fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        foreach (var sample in simulator.GetSamples().Take(100))
        {
            fsm.ProcessWeightSample(sample);
        }

        fsm.State.Should().Be(BatchProcessingState.Locked);
        fsm.ConfirmPrintSent("EPC001");
        fsm.State.Should().Be(BatchProcessingState.Printing);

        foreach (var sample in simulator.GetSamples().Skip(100))
        {
            fsm.ProcessWeightSample(sample);
        }

        fsm.State.Should().Be(BatchProcessingState.Paused);
        fsm.PauseReason.Should().Be(PauseReason.ReweighRequired);
    }

    private static BatchProcessingFsm CreateFsm()
    {
        var channel = System.Threading.Channels.Channel.CreateUnbounded<Titan.Domain.Events.DomainEvent>();
        var detector = new StabilityDetector();
        return new BatchProcessingFsm(channel, detector);
    }
}
