namespace Titan.Infrastructure.Hardware.Scale;

public interface IScalePort : IAsyncDisposable
{
    bool IsConnected { get; }
    Task<bool> ConnectAsync(string portName, int baudRate = 9600, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);
    IAsyncEnumerable<ScaleReading> ReadAsync(CancellationToken ct = default);
}

public sealed record ScaleReading(
    double Value,
    string Unit,
    bool IsStable,
    DateTime Timestamp
);
