using Titan.Domain.Entities;

namespace Titan.Domain.Interfaces;

public interface IRepository<T> where T : class
{
    Task<T?> GetByIdAsync(string id, CancellationToken ct = default);
    Task<IReadOnlyList<T>> GetAllAsync(CancellationToken ct = default);
    Task AddAsync(T entity, CancellationToken ct = default);
    Task UpdateAsync(T entity, CancellationToken ct = default);
    Task DeleteAsync(string id, CancellationToken ct = default);
}

public interface IProductRepository : IRepository<Product>
{
    Task<IReadOnlyList<Product>> GetByWarehouseAsync(string warehouseId, CancellationToken ct = default);
    Task<IReadOnlyList<Product>> GetAvailableForIssueAsync(string warehouseId, CancellationToken ct = default);
}

public interface IBatchRepository : IRepository<Batch>
{
    Task<Batch?> GetActiveAsync(CancellationToken ct = default);
}

public interface IWeightRecordRepository : IRepository<WeightRecord>
{
    Task<IReadOnlyList<WeightRecord>> GetUnsyncedAsync(CancellationToken ct = default);
    Task MarkAsSyncedAsync(string id, CancellationToken ct = default);
}
