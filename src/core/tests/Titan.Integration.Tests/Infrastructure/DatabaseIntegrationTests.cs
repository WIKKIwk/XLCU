using Xunit;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Titan.Infrastructure.Persistence;
using Titan.Domain.Entities;
using Titan.Infrastructure.Persistence.Repositories;
using Testcontainers.PostgreSql;

namespace Titan.Integration.Tests.Infrastructure;

public class DatabaseIntegrationTests : IAsyncLifetime
{
    private PostgreSqlContainer? _postgresContainer;
    private TitanDbContext? _dbContext;
    private ProductRepository? _productRepository;

    public async Task InitializeAsync()
    {
        _postgresContainer = new PostgreSqlBuilder()
            .WithDatabase("titan_test")
            .WithUsername("test")
            .WithPassword("test")
            .Build();

        await _postgresContainer.StartAsync();

        var options = new DbContextOptionsBuilder<TitanDbContext>()
            .UseNpgsql(_postgresContainer.GetConnectionString())
            .Options;

        _dbContext = new TitanDbContext(options);
        await _dbContext.Database.MigrateAsync();

        _productRepository = new ProductRepository(_dbContext);
    }

    public async Task DisposeAsync()
    {
        if (_dbContext != null)
            await _dbContext.DisposeAsync();

        if (_postgresContainer != null)
            await _postgresContainer.DisposeAsync();
    }

    [Fact]
    public async Task ProductRepository_AddAsync_Should_PersistToDatabase()
    {
        var product = new Product("PROD-TEST-001", "Test Product", "WH-001");

        await _productRepository!.AddAsync(product);

        var retrieved = await _productRepository.GetByIdAsync("PROD-TEST-001");
        retrieved.Should().NotBeNull();
        retrieved!.Name.Should().Be("Test Product");
    }

    [Fact]
    public async Task ProductRepository_GetByWarehouseAsync_Should_FilterByWarehouse()
    {
        var product1 = new Product("PROD-001", "Product 1", "WH-001");
        var product2 = new Product("PROD-002", "Product 2", "WH-002");
        var product3 = new Product("PROD-003", "Product 3", "WH-001");

        await _productRepository!.AddAsync(product1);
        await _productRepository.AddAsync(product2);
        await _productRepository.AddAsync(product3);

        var wh1Products = await _productRepository.GetByWarehouseAsync("WH-001");

        wh1Products.Should().HaveCount(2);
        wh1Products.Select(p => p.Id).Should().Contain(new[] { "PROD-001", "PROD-003" });
    }

    [Fact]
    public async Task ProductRepository_GetAvailableForIssueAsync_Should_FilterCorrectly()
    {
        var product1 = new Product("PROD-001", "Product 1", "WH-001");
        product1.MarkAsReceived();
        product1.AllowIssue();

        var product2 = new Product("PROD-002", "Product 2", "WH-001");
        product2.MarkAsReceived();

        var product3 = new Product("PROD-003", "Product 3", "WH-002");
        product3.MarkAsReceived();
        product3.AllowIssue();

        await _productRepository!.AddAsync(product1);
        await _productRepository.AddAsync(product2);
        await _productRepository.AddAsync(product3);

        var available = await _productRepository.GetAvailableForIssueAsync("WH-001");

        available.Should().HaveCount(1);
        available.First().Id.Should().Be("PROD-001");
    }

    [Fact]
    public async Task WeightRecordRepository_GetUnsyncedAsync_Should_ReturnOnlyUnsynced()
    {
        var repo = new WeightRecordRepository(_dbContext!);

        var record1 = new WeightRecord("BATCH-001", "PROD-001", 2.5, "kg", "EPC001");
        var record2 = new WeightRecord("BATCH-001", "PROD-001", 3.0, "kg", "EPC002");
        record2.MarkAsSynced();
        var record3 = new WeightRecord("BATCH-001", "PROD-001", 1.5, "kg", "EPC003");

        await repo.AddAsync(record1);
        await repo.AddAsync(record2);
        await repo.AddAsync(record3);

        var unsynced = await repo.GetUnsyncedAsync();

        unsynced.Should().HaveCount(2);
        unsynced.Select(r => r.EpcCode).Should().Contain(new[] { "EPC001", "EPC003" });
    }
}
