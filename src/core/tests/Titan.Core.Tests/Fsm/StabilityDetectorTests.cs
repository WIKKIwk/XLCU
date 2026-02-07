using Xunit;
using FluentAssertions;
using Titan.Core.Fsm;

namespace Titan.Core.Tests.Fsm;

public class StabilityDetectorTests
{
    private readonly StabilityDetector _detector;

    public StabilityDetectorTests()
    {
        _detector = new StabilityDetector();
    }

    [Fact]
    public void NewDetector_Should_NotBeStable()
    {
        _detector.IsStable.Should().BeFalse();
        _detector.TotalSamples.Should().Be(0);
    }

    [Theory]
    [InlineData(new double[] { 1.0, 1.01, 0.99, 1.0, 1.02, 0.98, 1.0, 1.01, 0.99, 1.0, 1.01, 0.99 }, true)]
    [InlineData(new double[] { 1.0, 1.5, 0.5, 1.0, 2.0 }, false)]
    public void AddSamples_Should_DetectStability(double[] weights, bool expectedStable)
    {
        var timestamp = GetTimestamp();

        for (int i = 0; i < weights.Length; i++)
        {
            _detector.AddSample(new WeightSample(weights[i], "kg", timestamp + i * 0.1));
        }

        _detector.IsStable.Should().Be(expectedStable);
        if (expectedStable)
        {
            _detector.Mean.Should().BeApproximately(1.0, 0.05);
        }
    }

    [Fact]
    public void Reset_Should_ClearAllSamples()
    {
        var timestamp = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _detector.AddSample(new WeightSample(1.0, "kg", timestamp + i * 0.1));
        }
        _detector.IsStable.Should().BeTrue();

        _detector.Reset();

        _detector.IsStable.Should().BeFalse();
        _detector.TotalSamples.Should().Be(0);
        _detector.Mean.Should().Be(0);
    }

    [Fact]
    public void OldSamples_Should_BeRemoved()
    {
        var timestamp = GetTimestamp();

        for (int i = 0; i < 10; i++)
        {
            _detector.AddSample(new WeightSample(1.0, "kg", timestamp + i * 0.1));
        }

        var oldCount = _detector.TotalSamples;

        _detector.AddSample(new WeightSample(2.0, "kg", timestamp + 10.0));

        _detector.TotalSamples.Should().BeLessThan(oldCount + 1);
    }

    [Fact]
    public void StdDev_Should_CalculateCorrectly()
    {
        var timestamp = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _detector.AddSample(new WeightSample(5.0, "kg", timestamp + i * 0.1));
        }

        _detector.StdDev.Should().BeApproximately(0, 0.001);
        _detector.Mean.Should().Be(5.0);
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}
