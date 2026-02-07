using Xunit;
using FluentAssertions;

namespace Titan.Integration.Tests.Hardware;

public class ScaleSimulationTests
{
    [Fact]
    public void ScaleReading_ParseValidData_Should_ReturnReading()
    {
        var testData = "ST,GS,   1.234,kg\r\n";

        var parsed = ParseScaleData(testData);

        parsed.Should().NotBeNull();
        parsed!.Value.Value.Should().BeApproximately(1.234, 0.001);
        parsed.Value.Unit.Should().Be("kg");
        parsed.Value.IsStable.Should().BeTrue();
    }

    [Fact]
    public void ScaleReading_ParseUnstableData_Should_DetectUnstable()
    {
        var testData = "US,GS,   0.123,kg\r\n";

        var parsed = ParseScaleData(testData);

        parsed.Should().NotBeNull();
        parsed!.Value.IsStable.Should().BeFalse();
    }

    private static (double Value, string Unit, bool IsStable)? ParseScaleData(string data)
    {
        if (data.Contains("ST"))
        {
            var parts = data.Split(',');
            if (parts.Length >= 4 && double.TryParse(parts[2], out var weight))
            {
                return (weight, parts[3].Trim(), true);
            }
        }
        else if (data.Contains("US"))
        {
            var parts = data.Split(',');
            if (parts.Length >= 4 && double.TryParse(parts[2], out var weight))
            {
                return (weight, parts[3].Trim(), false);
            }
        }
        return null;
    }
}
