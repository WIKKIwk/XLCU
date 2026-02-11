using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Infrastructure.Hardware.Printer;
using Titan.Infrastructure.Hardware.Scale;

namespace Titan.Host.Services;

public class ScaleReadingService : IHostedService
{
    private readonly ILogger<ScaleReadingService> _logger;
    private readonly IScalePort _scalePort;
    private readonly BatchProcessingService _batchService;
    private readonly IPrinterTransport _printer;
    private readonly IConfiguration _configuration;
    private CancellationTokenSource? _cts;
    private Task? _readingTask;

    public ScaleReadingService(
        ILogger<ScaleReadingService> logger,
        IScalePort scalePort,
        BatchProcessingService batchService,
        IPrinterTransport printer,
        IConfiguration configuration)
    {
        _logger = logger;
        _scalePort = scalePort;
        _batchService = batchService;
        _printer = printer;
        _configuration = configuration;
    }

    public async Task StartAsync(CancellationToken ct)
    {
        // Printer callback ulash — weight stabil bo'lganda chaqiriladi
        _batchService.OnPrintRequested = SendToPrinterAsync;

        // Printerga ulanish
        var printerPath = _configuration.GetValue<string>("Hardware:PrinterPort") ?? "/dev/usb/lp0";
        if (!_printer.IsConnected)
        {
            var connected = await _printer.ConnectAsync(printerPath, ct);
            if (connected)
                _logger.LogInformation("Printer connected: {Path}", printerPath);
            else
                _logger.LogWarning("Printer not available at {Path} — will print when connected", printerPath);
        }

        // Scale ulanish
        var portName = _configuration.GetValue<string>("Hardware:ScalePort") ?? "/dev/ttyUSB0";
        var baudRate = _configuration.GetValue<int>("Hardware:ScaleBaudRate", 9600);

        _logger.LogInformation("Connecting to scale on {Port}...", portName);

        if (await _scalePort.ConnectAsync(portName, baudRate, ct))
        {
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _readingTask = ReadScaleAsync(_cts.Token);
            _logger.LogInformation("Scale connected successfully");
        }
        else
        {
            _logger.LogWarning("Failed to connect to scale. Retrying in background...");
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _readingTask = RetryConnectionAsync(portName, baudRate, _cts.Token);
        }
    }

    public async Task StopAsync(CancellationToken ct)
    {
        _cts?.Cancel();

        if (_readingTask != null)
        {
            try
            {
                await _readingTask.WaitAsync(TimeSpan.FromSeconds(5), ct);
            }
            catch (OperationCanceledException) { }
            catch (TimeoutException) { }
        }

        await _scalePort.DisconnectAsync(ct);
    }

    private async Task ReadScaleAsync(CancellationToken ct)
    {
        try
        {
            // Avtomatik batch boshlash
            _batchService.AutoStart();

            await foreach (var reading in _scalePort.ReadAsync(ct))
            {
                _batchService.ProcessWeight(reading.Value, reading.Unit);
                _logger.LogDebug("Weight: {Value} {Unit} (Stable: {Stable})",
                    reading.Value, reading.Unit, reading.IsStable);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error reading from scale");
        }
    }

    private async Task RetryConnectionAsync(string portName, int baudRate, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);

                if (await _scalePort.ConnectAsync(portName, baudRate, ct))
                {
                    _logger.LogInformation("Scale reconnected on {Port}", portName);
                    await ReadScaleAsync(ct);
                    break;
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Retry connection failed");
            }
        }
    }

    /// <summary>
    /// Printer callback — BatchProcessingService chaqiradi weight stabil bo'lganda.
    /// </summary>
    private async Task<bool> SendToPrinterAsync(double weight, string unit, string epcCode, string productId)
    {
        var zpl = $"""
            ^XA
            ^FO50,50^A0N,40,40^FDProduct: {productId}^FS
            ^FO50,110^A0N,50,50^FDWeight: {weight:F3} {unit}^FS
            ^FO50,180^A0N,30,30^FDEPC: {epcCode}^FS
            ^FO50,230^A0N,25,25^FD{DateTime.Now:yyyy-MM-dd HH:mm:ss}^FS
            ^RFW,H^FD{epcCode}^FS
            ^XZ
            """;

        if (!_printer.IsConnected)
        {
            _logger.LogWarning("Printer not connected — print skipped");
            return false;
        }

        var result = await _printer.SendAsync(zpl);
        if (result.Success)
        {
            _logger.LogInformation("ZPL sent to printer, job: {Job}", result.JobId);
            return true;
        }

        _logger.LogError("Printer send failed: {Error}", result.ErrorMessage);
        return false;
    }
}
