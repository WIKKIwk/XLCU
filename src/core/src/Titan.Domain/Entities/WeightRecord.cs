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
