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
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        _service.ActiveBatchId.Should().Be("BATCH-001");
        _service.ActiveProductId.Should().Be("PROD-001");
        _service.CurrentState.Should().Be(BatchProcessingState.WaitEmpty);
    }

    [Fact]
    public void StopBatch_Should_ClearActiveBatch()
    {
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        _service.StopBatch();

        _service.CurrentState.Should().Be(BatchProcessingState.Paused);
    }

    [Fact]
    public void ProcessWeight_Should_UpdateFSM()
    {
        _service.StartBatch("BATCH-001", "PROD-001", 1.0);

        _service.ProcessWeight(2.5, "kg");

        _service.CurrentState.Should().NotBe(BatchProcessingState.Idle);
    }

    [Fact]
    public async Task ConfirmPrintAsync_Should_GenerateEpc()
    {
        _epcGeneratorMock.Setup(x => x.GenerateNextAsync())
            .ReturnsAsync("3034257BF7194E4000000001");

        await _service.ConfirmPrintAsync();

        _epcGeneratorMock.Verify(x => x.GenerateNextAsync(), Times.Once);
    }
}
