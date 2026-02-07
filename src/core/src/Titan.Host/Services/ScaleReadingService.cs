using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Infrastructure.Hardware.Scale;

namespace Titan.Host.Services;

public class ScaleReadingService : IHostedService
{
    private readonly ILogger<ScaleReadingService> _logger;
    private readonly IScalePort _scalePort;
    private readonly BatchProcessingService _batchService;
    private readonly IConfiguration _configuration;
    private CancellationTokenSource? _cts;
    private Task? _readingTask;

    public ScaleReadingService(
        ILogger<ScaleReadingService> logger,
        IScalePort scalePort,
        BatchProcessingService batchService,
        IConfiguration configuration)
    {
        _logger = logger;
        _scalePort = scalePort;
        _batchService = batchService;
        _configuration = configuration;
    }

    public async Task StartAsync(CancellationToken ct)
    {
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
}
