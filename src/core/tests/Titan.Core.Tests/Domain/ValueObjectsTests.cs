using Xunit;
using FluentAssertions;
using Titan.Domain.ValueObjects;

namespace Titan.Core.Tests.Domain;

public class ValueObjectsTests
{
    [Fact]
    public void EpcCode_Create_Should_FormatCorrectly()
    {
        var epc = EpcCode.Create("3034257BF7194E4", 1);

        epc.Value.Should().Be("3034257BF7194E400000001");
        epc.Value.Length.Should().Be(24);
    }

    [Fact]
    public void EpcCode_Create_Should_PadCounter()
    {
        var epc = EpcCode.Create("3034257BF7194E4", 12345);

        epc.Value.Should().Contain("000012345");
    }

    [Fact]
    public void EpcCode_FromString_ValidFormat_Should_Parse()
    {
        var epc = EpcCode.FromString("3034257BF7194E400000001");

        epc.Value.Should().Be("3034257BF7194E400000001");
    }

    [Theory]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("3034257BF7194E4000000011")]
    public void EpcCode_FromString_InvalidFormat_ShouldThrow(string value)
    {
        FluentActions.Invoking(() => EpcCode.FromString(value))
            .Should().Throw<ArgumentException>();
    }

    [Fact]
    public void EpcCode_Equality_SameValue_ShouldBeEqual()
    {
        var epc1 = EpcCode.Create("3034257BF7194E4", 1);
        var epc2 = EpcCode.Create("3034257BF7194E4", 1);

        epc1.Should().Be(epc2);
        epc1.GetHashCode().Should().Be(epc2.GetHashCode());
    }
}
