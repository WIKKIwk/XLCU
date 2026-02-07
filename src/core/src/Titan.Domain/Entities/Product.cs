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
