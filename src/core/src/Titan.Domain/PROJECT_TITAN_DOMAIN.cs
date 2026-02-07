// ============================================
// TITAN.DOMAIN - Domain Layer
// ============================================
// File: src/Titan.Domain/Titan.Domain.csproj
/*
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Titan.Domain</RootNamespace>
    <LangVersion>14.0</LangVersion>
  </PropertyGroup>
</Project>
*/

// ============================================
// File: src/Titan.Domain/Entities/Product.cs
// ============================================
namespace Titan.Domain.Entities;

public sealed class Product
{
    public string Id { get; }
    public string Name { get; }
    public string? Description { get; }
    public string WarehouseId { get; }
    public bool IsReceived { get; private set; }
    public bool CanIssue { get; private set; }
    public DateTime CreatedAt { get; }

    public Product(string id, string name, string warehouseId)
    {
        Id = id ?? throw new ArgumentNullException(nameof(id));
        Name = name ?? throw new ArgumentNullException(nameof(name));
        WarehouseId = warehouseId ?? throw new ArgumentNullException(nameof(warehouseId));
        CreatedAt = DateTime.UtcNow;
        IsReceived = false;
        CanIssue = false;
    }

    public void MarkAsReceived() => IsReceived = true;
    public void AllowIssue() => CanIssue = true;
    public void DisallowIssue() => CanIssue = false;
}

// ============================================
// File: src/Titan.Domain/Entities/Batch.cs
// ============================================
namespace Titan.Domain.Entities;

public sealed class Batch
{
    public string Id { get; }
    public string Name { get; }
    public string WarehouseId { get; }
    public BatchStatus Status { get; private set; }
    public string? CurrentProductId { get; private set; }
    public DateTime StartedAt { get; }
    public DateTime? CompletedAt { get; private set; }

    public Batch(string id, string name, string warehouseId)
    {
        Id = id;
        Name = name;
        WarehouseId = warehouseId;
        Status = BatchStatus.Created;
        StartedAt = DateTime.UtcNow;
    }

    public void Start() => Status = BatchStatus.Running;
    public void Pause() => Status = BatchStatus.Paused;
    public void Complete()
    {
        Status = BatchStatus.Completed;
        CompletedAt = DateTime.UtcNow;
    }
    public void SetProduct(string productId) => CurrentProductId = productId;
}

public enum BatchStatus
{
    Created,
    Running,
    Paused,
    Completed,
    Cancelled
}

// ============================================
// File: src/Titan.Domain/Entities/WeightRecord.cs
// ============================================
namespace Titan.Domain.Entities;

public sealed class WeightRecord
{
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string BatchId { get; }
    public string ProductId { get; }
    public double Weight { get; }
    public string Unit { get; }
    public string EpcCode { get; }
    public DateTime RecordedAt { get; }
    public bool IsSynced { get; private set; }
    public DateTime? SyncedAt { get; private set; }

    public WeightRecord(string batchId, string productId, double weight, string unit, string epcCode)
    {
        BatchId = batchId;
        ProductId = productId;
        Weight = weight;
        Unit = unit;
        EpcCode = epcCode;
        RecordedAt = DateTime.UtcNow;
    }

    public void MarkAsSynced()
    {
        IsSynced = true;
        SyncedAt = DateTime.UtcNow;
    }
}

// ============================================
// File: src/Titan.Domain/ValueObjects/EpcCode.cs
// ============================================
namespace Titan.Domain.ValueObjects;

public sealed record EpcCode
{
    public string Value { get; }
    
    private EpcCode(string value) => Value = value;

    public static EpcCode Create(string prefix, long counter)
    {
        // EPC Gen2 96-bit format: prefix (hex) + counter (hex, padded to 12 chars)
        var hexCounter = counter.ToString("X12");
        return new EpcCode($"{prefix}{hexCounter}");
    }

    public static EpcCode FromString(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length != 24)
            throw new ArgumentException("Invalid EPC code format");
        return new EpcCode(value.ToUpper());
    }

    public override string ToString() => Value;
}

// ============================================
// File: src/Titan.Domain/Events/DomainEvent.cs
// ============================================
namespace Titan.Domain.Events;

public abstract record DomainEvent
{
    public string EventId { get; } = Guid.NewGuid().ToString("N");
    public DateTime OccurredAt { get; } = DateTime.UtcNow;
}

public record WeightStabilizedEvent(
    string BatchId,
    string ProductId,
    double Weight,
    string Unit
) : DomainEvent;

public record LabelPrintedEvent(
    string BatchId,
    string ProductId,
    string EpcCode,
    double Weight
) : DomainEvent;

public record BatchStartedEvent(string BatchId) : DomainEvent;
public record BatchCompletedEvent(string BatchId) : DomainEvent;
public record ProductChangedEvent(string BatchId, string ProductId) : DomainEvent;

// ============================================
// File: src/Titan.Domain/Interfaces/IRepository.cs
// ============================================
namespace Titan.Domain.Interfaces;

public interface IRepository<T> where T : class
{
    Task<T?> GetByIdAsync(string id, CancellationToken ct = default);
    Task<IReadOnlyList<T>> GetAllAsync(CancellationToken ct = default);
    Task AddAsync(T entity, CancellationToken ct = default);
    Task UpdateAsync(T entity, CancellationToken ct = default);
    Task DeleteAsync(string id, CancellationToken ct = default);
}

public interface IProductRepository : IRepository<Product.Entities.Product>
{
    Task<IReadOnlyList<Entities.Product>> GetByWarehouseAsync(string warehouseId, CancellationToken ct = default);
    Task<IReadOnlyList<Entities.Product>> GetAvailableForIssueAsync(string warehouseId, CancellationToken ct = default);
}

public interface IBatchRepository : IRepository<Entities.Batch>
{
    Task<Entities.Batch?> GetActiveAsync(CancellationToken ct = default);
}

public interface IWeightRecordRepository : IRepository<Entities.WeightRecord>
{
    Task<IReadOnlyList<Entities.WeightRecord>> GetUnsyncedAsync(CancellationToken ct = default);
    Task MarkAsSyncedAsync(string id, CancellationToken ct = default);
}

// ============================================
// File: src/Titan.Domain/Interfaces/ICacheService.cs
// ============================================
namespace Titan.Domain.Interfaces;

public interface ICacheService
{
    Task<T?> GetAsync<T>(string key, CancellationToken ct = default) where T : class;
    Task SetAsync<T>(string key, T value, TimeSpan? expiration = null, CancellationToken ct = default) where T : class;
    Task RemoveAsync(string key, CancellationToken ct = default);
    Task<bool> ExistsAsync(string key, CancellationToken ct = default);
}
