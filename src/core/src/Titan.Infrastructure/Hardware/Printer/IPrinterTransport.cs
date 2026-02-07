namespace Titan.Infrastructure.Hardware.Printer;

public interface IPrinterTransport : IAsyncDisposable
{
    bool IsConnected { get; }
    bool SupportsStatusQuery { get; }

    Task<bool> ConnectAsync(string connectionString, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);
    Task<PrintResult> SendAsync(string zplData, CancellationToken ct = default);
    Task<PrinterStatus?> QueryStatusAsync(CancellationToken ct = default);
}

public sealed record PrintResult(
    bool Success,
    string? ErrorMessage = null,
    string? JobId = null
);

public sealed record PrinterStatus(
    bool IsReady,
    bool IsPaused,
    bool HasError,
    bool PaperOut,
    bool RibbonOut,
    bool HeadOpen,
    string? ErrorMessage = null
);
