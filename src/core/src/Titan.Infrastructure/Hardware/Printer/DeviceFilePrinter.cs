using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Hardware.Printer;

public class DeviceFilePrinter : IPrinterTransport
{
    private readonly ILogger<DeviceFilePrinter> _logger;
    private string? _devicePath;
    private FileStream? _fileStream;

    public bool IsConnected => _fileStream != null;
    public bool SupportsStatusQuery => false;

    public DeviceFilePrinter(ILogger<DeviceFilePrinter> logger) => _logger = logger;

    public Task<bool> ConnectAsync(string connectionString, CancellationToken ct = default)
    {
        try
        {
            _devicePath = connectionString;
            _fileStream = new FileStream(_devicePath, FileMode.Open, FileAccess.Write, FileShare.None);
            _logger.LogInformation("Printer connected: {Path}", _devicePath);
            return Task.FromResult(true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to printer: {Path}", connectionString);
            return Task.FromResult(false);
        }
    }

    public Task DisconnectAsync(CancellationToken ct = default)
    {
        _fileStream?.Dispose();
        _fileStream = null;
        _logger.LogInformation("Printer disconnected");
        return Task.CompletedTask;
    }

    public async Task<PrintResult> SendAsync(string zplData, CancellationToken ct = default)
    {
        if (_fileStream == null)
            return new PrintResult(false, "Printer not connected");

        try
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(zplData);
            await _fileStream.WriteAsync(bytes, ct);
            await _fileStream.FlushAsync(ct);

            _logger.LogDebug("Sent {Bytes} bytes to printer", bytes.Length);
            return new PrintResult(true, JobId: Guid.NewGuid().ToString("N")[..8]);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send data to printer");
            return new PrintResult(false, ex.Message);
        }
    }

    public Task<PrinterStatus?> QueryStatusAsync(CancellationToken ct = default)
        => Task.FromResult<PrinterStatus?>(null);

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync();
    }
}
