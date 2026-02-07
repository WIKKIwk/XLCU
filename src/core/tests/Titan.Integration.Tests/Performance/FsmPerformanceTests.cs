using Xunit;
using FluentAssertions;
using System.Diagnostics;
using Titan.Core.Fsm;

namespace Titan.Integration.Tests.Performance;

public class FsmPerformanceTests
{
    [Fact]
    public void Fsm_ProcessWeightSamples_10000Samples_Should_CompleteQuickly()
    {
        var fsm = CreateFsm();
        fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        var samples = Enumerable.Range(0, 10000)
            .Select(i => new WeightSample(2.5, "kg", i * 0.01))
            .ToList();

        var stopwatch = Stopwatch.StartNew();

        foreach (var sample in samples)
        {
            fsm.ProcessWeightSample(sample);
        }

        stopwatch.Stop();

        stopwatch.ElapsedMilliseconds.Should().BeLessThan(100);
    }

    [Fact]
    public void StabilityDetector_AddSamples_10000Samples_Should_MaintainPerformance()
    {
        var detector = new StabilityDetector();
        var samples = Enumerable.Range(0, 10000)
            .Select(i => new WeightSample(2.5 + (i % 10) * 0.001, "kg", i * 0.01))
            .ToList();

        var stopwatch = Stopwatch.StartNew();

        foreach (var sample in samples)
        {
            detector.AddSample(sample);
        }

        stopwatch.Stop();

        stopwatch.ElapsedMilliseconds.Should().BeLessThan(200);
        detector.TotalSamples.Should().BeLessThan(100);
    }

    private static BatchProcessingFsm CreateFsm()
    {
        var channel = System.Threading.Channels.Channel.CreateUnbounded<Titan.Domain.Events.DomainEvent>();
        var detector = new StabilityDetector();
        return new BatchProcessingFsm(channel, detector);
    }
}
