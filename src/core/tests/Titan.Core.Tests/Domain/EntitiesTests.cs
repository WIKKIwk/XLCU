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
        var product = new Product("PROD-001", "Test Product", "WH-001");

        product.Id.Should().Be("PROD-001");
        product.Name.Should().Be("Test Product");
        product.WarehouseId.Should().Be("WH-001");
        product.IsReceived.Should().BeFalse();
        product.CanIssue.Should().BeFalse();
    }

    [Fact]
    public void Product_MarkAsReceived_Should_UpdateStatus()
    {
        var product = new Product("PROD-001", "Test", "WH-001");

        product.MarkAsReceived();

        product.IsReceived.Should().BeTrue();
    }

    [Fact]
    public void Batch_Constructor_Should_SetDefaults()
    {
        var batch = new Batch("BATCH-001", "Test Batch", "WH-001");

        batch.Id.Should().Be("BATCH-001");
        batch.Status.Should().Be(BatchStatus.Created);
        batch.CompletedAt.Should().BeNull();
    }

    [Fact]
    public void Batch_Complete_Should_SetStatusAndTimestamp()
    {
        var batch = new Batch("BATCH-001", "Test", "WH-001");

        batch.Complete();

        batch.Status.Should().Be(BatchStatus.Completed);
        batch.CompletedAt.Should().NotBeNull();
    }

    [Fact]
    public void WeightRecord_Constructor_Should_GenerateId()
    {
        var record = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");

        record.Id.Should().NotBeNullOrEmpty();
        record.BatchId.Should().Be("BATCH-001");
        record.Weight.Should().Be(2.5);
        record.IsSynced.Should().BeFalse();
    }

    [Fact]
    public void WeightRecord_MarkAsSynced_Should_UpdateStatus()
    {
        var record = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");

        record.MarkAsSynced();

        record.IsSynced.Should().BeTrue();
        record.SyncedAt.Should().NotBeNull();
    }
}
