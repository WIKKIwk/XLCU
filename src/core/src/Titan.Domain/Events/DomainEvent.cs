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
