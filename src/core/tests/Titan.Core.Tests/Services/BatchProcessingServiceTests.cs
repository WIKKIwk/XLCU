using Xunit;
using FluentAssertions;
using Moq;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Core.Fsm;

namespace Titan.Core.Tests.Services;

public class BatchProcessingServiceTests : IDisposable
{
    private readonly Mock<IEpcGenerator> _epcGeneratorMock;
    private readonly Mock<ILogger<BatchProcessingService>> _loggerMock;
    private readonly JsonFileRecordStore _recordStore;
    private readonly BatchProcessingService _service;
    private readonly string _tempDir;

    public BatchProcessingServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"titan-test-{Guid.NewGuid():N}");
        _epcGeneratorMock = new Mock<IEpcGenerator>();
        _epcGeneratorMock.Setup(x => x.GenerateNextAsync())
            .ReturnsAsync("TEST-EPC-001");
        _loggerMock = new Mock<ILogger<BatchProcessingService>>();
        _recordStore = new JsonFileRecordStore(_tempDir);

        _service = new BatchProcessingService(
            _epcGeneratorMock.Object,
            _recordStore,
            _loggerMock.Object);
    }

    public void Dispose()
    {
        _service.Dispose();
        try { Directory.Delete(_tempDir, true); } catch { }
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
    public void AutoStart_Should_SetActiveBatch()
    {
        _service.AutoStart("TEST-PRODUCT");

        _service.ActiveBatchId.Should().NotBeNull();
        _service.ActiveProductId.Should().Be("TEST-PRODUCT");
        _service.CurrentState.Should().Be(BatchProcessingState.WaitEmpty);
    }
}
