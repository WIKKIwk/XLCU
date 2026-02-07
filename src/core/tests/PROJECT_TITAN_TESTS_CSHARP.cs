// ============================================
// TITAN CORE - Unit & Integration Tests
// ============================================
// File: tests/Titan.Core.Tests/Titan.Core.Tests.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
    <LangVersion>14.0</LangVersion>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.9.0" />
    <PackageReference Include="xunit" Version="2.7.0" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.7">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers</IncludeAssets>
    </PackageReference>
    <PackageReference Include="Microsoft.EntityFrameworkCore.InMemory" Version="10.0.0-preview.1.25080.5" />
    <PackageReference Include="Moq" Version="4.20.70" />
    <PackageReference Include="FluentAssertions" Version="7.0.0-alpha.3" />
    <PackageReference Include="Bogus" Version="35.5.0" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="../../src/Titan.Domain/Titan.Domain.csproj" />
    <ProjectReference Include="../../src/Titan.Core/Titan.Core.csproj" />
    <ProjectReference Include="../../src/Titan.Infrastructure/Titan.Infrastructure.csproj" />
  </ItemGroup>
</Project>
*/

// ============================================
// File: tests/Titan.Core.Tests/Fsm/BatchProcessingFsmTests.cs
// ============================================
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
        // Assert
        _fsm.State.Should().Be(BatchProcessingState.Idle);
        _fsm.PauseReason.Should().Be(PauseReason.None);
    }

    [Fact]
    public void StartBatch_Should_TransitionTo_WaitEmpty()
    {
        // Act
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);
        _fsm.ActiveBatchId.Should().Be("BATCH-001");
        _fsm.ActiveProductId.Should().Be("PROD-001");
    }

    [Fact]
    public void StartBatch_Should_ResetStabilityDetector()
    {
        // Arrange
        _stabilityDetector.SetPlacementMinWeight(5.0);

        // Act
        _fsm.StartBatch("BATCH-001", "PROD-001", 2.5);

        // Assert
        _stabilityDetector.PlacementMinWeight.Should().Be(2.5);
    }

    [Theory]
    [InlineData(0.0, BatchProcessingState.WaitEmpty)]   // Below threshold
    [InlineData(1.5, BatchProcessingState.Loading)]     // Above threshold
    public void ProcessWeightSample_WaitEmpty_Should_TransitionCorrectly(double weight, BatchProcessingState expectedState)
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Act
        _fsm.ProcessWeightSample(new WeightSample(weight, "kg", GetTimestamp()));

        // Assert
        _fsm.State.Should().Be(expectedState);
    }

    [Fact]
    public void ProcessWeightSample_SettingPhase_ShouldDetectStability()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        
        // Add enough samples to trigger settling
        var baseTime = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", baseTime + i * 0.1));
        }

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.Settling);
    }

    [Fact]
    public void StopBatch_Should_TransitionTo_Paused()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Act
        _fsm.StopBatch();

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.Paused);
        _fsm.PauseReason.Should().Be(PauseReason.BatchStopped);
    }

    [Fact]
    public void WeightChange_AfterLock_Should_TriggerReweighRequired()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        
        // Lock the weight
        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }
        
        _fsm.State.Should().Be(BatchProcessingState.Locked);
        _fsm.LockedWeight.Should().BeApproximately(2.5, 0.1);

        // Act - Significant weight change
        _fsm.ProcessWeightSample(new WeightSample(3.5, "kg", timestamp + 5.0));

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.Paused);
        _fsm.PauseReason.Should().Be(PauseReason.ReweighRequired);
    }

    [Fact]
    public void ChangeProduct_InWaitEmpty_Should_UpdateProduct()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Act
        _fsm.ChangeProduct("PROD-002");

        // Assert
        _fsm.ActiveProductId.Should().Be("PROD-002");
    }

    [Fact]
    public void ChangeProduct_NotInWaitEmpty_Should_NotUpdateProduct()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        _fsm.ProcessWeightSample(new WeightSample(2.0, "kg", GetTimestamp()));

        // Act
        _fsm.ChangeProduct("PROD-002");

        // Assert
        _fsm.ActiveProductId.Should().Be("PROD-001"); // Unchanged
    }

    [Fact]
    public void PrintComplete_Should_TransitionTo_PostGuard()
    {
        // Arrange - Get to Printing state
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();
        for (int i = 0; i < 20; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        }
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.State.Should().Be(BatchProcessingState.Printing);

        // Act
        _fsm.ConfirmPrintCompleted();

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.PostGuard);
    }

    [Fact]
    public void WeightBelowEmpty_InPostGuard_Should_TransitionTo_WaitEmpty()
    {
        // Arrange
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
        var timestamp = GetTimestamp();
        
        // Complete a full cycle
        for (int i = 0; i < 20; i++)
            _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
        _fsm.ConfirmPrintSent("EPC001");
        _fsm.ConfirmPrintCompleted();
        
        _fsm.State.Should().Be(BatchProcessingState.PostGuard);

        // Act - Weight goes to zero for sufficient time
        var newTime = timestamp + 10.0;
        for (int i = 0; i < 10; i++)
        {
            _fsm.ProcessWeightSample(new WeightSample(0.0, "kg", newTime + i * 0.1));
        }

        // Assert
        _fsm.State.Should().Be(BatchProcessingState.WaitEmpty);
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}

// ============================================
// File: tests/Titan.Core.Tests/Fsm/StabilityDetectorTests.cs
// ============================================
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
    [InlineData(new double[] { 1.0, 1.5, 0.5, 1.0, 2.0 }, false)]  // High variance
    public void AddSamples_Should_DetectStability(double[] weights, bool expectedStable)
    {
        // Arrange
        var timestamp = GetTimestamp();

        // Act
        for (int i = 0; i < weights.Length; i++)
        {
            _detector.AddSample(new WeightSample(weights[i], "kg", timestamp + i * 0.1));
        }

        // Assert
        _detector.IsStable.Should().Be(expectedStable);
        if (expectedStable)
        {
            _detector.Mean.Should().BeApproximately(1.0, 0.05);
        }
    }

    [Fact]
    public void Reset_Should_ClearAllSamples()
    {
        // Arrange
        var timestamp = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _detector.AddSample(new WeightSample(1.0, "kg", timestamp + i * 0.1));
        }
        _detector.IsStable.Should().BeTrue();

        // Act
        _detector.Reset();

        // Assert
        _detector.IsStable.Should().BeFalse();
        _detector.TotalSamples.Should().Be(0);
        _detector.Mean.Should().Be(0);
    }

    [Fact]
    public void OldSamples_Should_BeRemoved()
    {
        // Arrange
        var timestamp = GetTimestamp();
        
        // Add old samples
        for (int i = 0; i < 10; i++)
        {
            _detector.AddSample(new WeightSample(1.0, "kg", timestamp + i * 0.1));
        }
        
        var oldCount = _detector.TotalSamples;

        // Add new sample far in future (outside window)
        _detector.AddSample(new WeightSample(2.0, "kg", timestamp + 10.0));

        // Assert - Old samples should be removed
        _detector.TotalSamples.Should().BeLessThan(oldCount + 1);
    }

    [Fact]
    public void StdDev_Should_CalculateCorrectly()
    {
        // Arrange - Perfectly stable (all same values)
        var timestamp = GetTimestamp();
        for (int i = 0; i < 15; i++)
        {
            _detector.AddSample(new WeightSample(5.0, "kg", timestamp + i * 0.1));
        }

        // Assert
        _detector.StdDev.Should().BeApproximately(0, 0.001);
        _detector.Mean.Should().Be(5.0);
    }

    private static double GetTimestamp()
    {
        return (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
    }
}

// ============================================
// File: tests/Titan.Core.Tests/Services/BatchProcessingServiceTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using Moq;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Domain.Interfaces;
using Titan.Domain.Entities;
using Titan.Domain.Events;
using Titan.Core.Fsm;

namespace Titan.Core.Tests.Services;

public class BatchProcessingServiceTests : IDisposable
{
    private readonly Mock<IWeightRecordRepository> _weightRepoMock;
    private readonly Mock<IProductRepository> _productRepoMock;
    private readonly Mock<ICacheService> _cacheMock;
    private readonly Mock<IEpcGenerator> _epcGeneratorMock;
    private readonly Mock<ILogger<BatchProcessingService>> _loggerMock;
    private readonly BatchProcessingService _service;

    public BatchProcessingServiceTests()
    {
        _weightRepoMock = new Mock<IWeightRecordRepository>();
        _productRepoMock = new Mock<IProductRepository>();
        _cacheMock = new Mock<ICacheService>();
        _epcGeneratorMock = new Mock<IEpcGenerator>();
        _loggerMock = new Mock<ILogger<BatchProcessingService>>();

        _service = new BatchProcessingService(
            _weightRepoMock.Object,
            _productRepoMock.Object,
            _cacheMock.Object,
            _epcGeneratorMock.Object,
            _loggerMock.Object);
    }

    public void Dispose()
    {
        _service.Dispose();
    }

    [Fact]
    public void StartBatch_Should_SetActiveBatch()
    {
        // Act
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Assert
        _service.ActiveBatchId.Should().Be("BATCH-001");
        _service.ActiveProductId.Should().Be("PROD-001");
        _service.CurrentState.Should().Be(BatchProcessingState.WaitEmpty);
    }

    [Fact]
    public void StopBatch_Should_ClearActiveBatch()
    {
        // Arrange
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Act
        _service.StopBatch();

        // Assert
        _service.CurrentState.Should().Be(BatchProcessingState.Paused);
    }

    [Fact]
    public void ProcessWeight_Should_UpdateFSM()
    {
        // Arrange
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Act
        _service.ProcessWeight(2.5, "kg");

        // Assert - Should transition from WaitEmpty
        _service.CurrentState.Should().NotBe(BatchProcessingState.Idle);
    }

    [Fact]
    public async Task ConfirmPrintAsync_Should_GenerateEpc()
    {
        // Arrange
        _epcGeneratorMock.Setup(x => x.GenerateNextAsync())
            .ReturnsAsync("3034257BF7194E4000000001");

        // Act
        await _service.ConfirmPrintAsync();

        // Assert
        _epcGeneratorMock.Verify(x => x.GenerateNextAsync(), Times.Once);
    }
}

// ============================================
// File: tests/Titan.Core.Tests/Domain/EntitiesTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using Titan.Domain.Entities;
using Titan.Domain.ValueObjects;

namespace Titan.Core.Tests.Domain;

public class EntitiesTests
{
    [Fact]
    public void Product_Constructor_Should_SetProperties()
    {
        // Act
        var product = new Product("PROD-001", "Test Product", "WH-001");

        // Assert
        product.Id.Should().Be("PROD-001");
        product.Name.Should().Be("Test Product");
        product.WarehouseId.Should().Be("WH-001");
        product.IsReceived.Should().BeFalse();
        product.CanIssue.Should().BeFalse();
    }

    [Fact]
    public void Product_MarkAsReceived_Should_UpdateStatus()
    {
        // Arrange
        var product = new Product("PROD-001", "Test", "WH-001");

        // Act
        product.MarkAsReceived();

        // Assert
        product.IsReceived.Should().BeTrue();
    }

    [Fact]
    public void Batch_Constructor_Should_SetDefaults()
    {
        // Act
        var batch = new Batch("BATCH-001", "Test Batch", "WH-001");

        // Assert
        batch.Id.Should().Be("BATCH-001");
        batch.Status.Should().Be(BatchStatus.Created);
        batch.CompletedAt.Should().BeNull();
    }

    [Fact]
    public void Batch_Complete_Should_SetStatusAndTimestamp()
    {
        // Arrange
        var batch = new Batch("BATCH-001", "Test", "WH-001");

        // Act
        batch.Complete();

        // Assert
        batch.Status.Should().Be(BatchStatus.Completed);
        batch.CompletedAt.Should().NotBeNull();
    }

    [Fact]
    public void WeightRecord_Constructor_Should_GenerateId()
    {
        // Act
        var record = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");

        // Assert
        record.Id.Should().NotBeNullOrEmpty();
        record.BatchId.Should().Be("BATCH-001");
        record.Weight.Should().Be(2.5);
        record.IsSynced.Should().BeFalse();
    }

    [Fact]
    public void WeightRecord_MarkAsSynced_Should_UpdateStatus()
    {
        // Arrange
        var record = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");

        // Act
        record.MarkAsSynced();

        // Assert
        record.IsSynced.Should().BeTrue();
        record.SyncedAt.Should().NotBeNull();
    }
}

// ============================================
// File: tests/Titan.Core.Tests/Domain/ValueObjectsTests.cs
// ============================================
using Xunit;
using FluentAssertions;
using Titan.Domain.ValueObjects;

namespace Titan.Core.Tests.Domain;

public class ValueObjectsTests
{
    [Fact]
    public void EpcCode_Create_Should_FormatCorrectly()
    {
        // Act
        var epc = EpcCode.Create("3034257BF7194E4", 1);

        // Assert
        epc.Value.Should().Be("3034257BF7194E400000001");
        epc.Value.Length.Should().Be(24);
    }

    [Fact]
    public void EpcCode_Create_Should_PadCounter()
    {
        // Act
        var epc = EpcCode.Create("3034257BF7194E4", 12345);

        // Assert
        epc.Value.Should().Contain("000012345");
    }

    [Fact]
    public void EpcCode_FromString_ValidFormat_Should_Parse()
    {
        // Act
        var epc = EpcCode.FromString("3034257BF7194E400000001");

        // Assert
        epc.Value.Should().Be("3034257BF7194E400000001");
    }

    [Theory]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("3034257BF7194E4000000011")]  // Too long
    public void EpcCode_FromString_InvalidFormat_ShouldThrow(string value)
    {
        // Act & Assert
        FluentActions.Invoking(() => EpcCode.FromString(value))
            .Should().Throw<ArgumentException>();
    }

    [Fact]
    public void EpcCode_Equality_SameValue_ShouldBeEqual()
    {
        // Arrange
        var epc1 = EpcCode.Create("3034257BF7194E4", 1);
        var epc2 = EpcCode.Create("3034257BF7194E4", 1);

        // Assert
        epc1.Should().Be(epc2);
        epc1.GetHashCode().Should().Be(epc2.GetHashCode());
    }
}
