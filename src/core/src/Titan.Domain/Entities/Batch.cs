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
