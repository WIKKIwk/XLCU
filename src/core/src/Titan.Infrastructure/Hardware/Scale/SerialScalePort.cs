using System.IO.Ports;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Hardware.Scale;

public partial class SerialScalePort : IScalePort
{
    private SerialPort? _serialPort;
    private readonly ILogger<SerialScalePort> _logger;
    private readonly TimeSpan _readTimeout = TimeSpan.FromMilliseconds(100);

    public bool IsConnected => _serialPort?.IsOpen ?? false;

    public SerialScalePort(ILogger<SerialScalePort> logger) => _logger = logger;

    public Task<bool> ConnectAsync(string portName, int baudRate = 9600, CancellationToken ct = default)
    {
        try
        {
            _serialPort = new SerialPort(portName, baudRate)
            {
                Parity = Parity.None,
                DataBits = 8,
                StopBits = StopBits.One,
                ReadTimeout = (int)_readTimeout.TotalMilliseconds,
                WriteTimeout = 1000
            };

            _serialPort.Open();
            _logger.LogInformation("Scale connected on {Port}", portName);
            return Task.FromResult(true);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to scale on {Port}", portName);
            return Task.FromResult(false);
        }
    }

    public Task DisconnectAsync(CancellationToken ct = default)
    {
        _serialPort?.Close();
        _serialPort?.Dispose();
        _serialPort = null;
        _logger.LogInformation("Scale disconnected");
        return Task.CompletedTask;
    }

    public async IAsyncEnumerable<ScaleReading> ReadAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        if (_serialPort == null || !IsConnected)
            yield break;

        var buffer = new byte[256];
        var lineBuffer = new List<byte>();

        while (!ct.IsCancellationRequested && IsConnected)
        {
            int bytesRead;
            try
            {
                bytesRead = await _serialPort.BaseStream.ReadAsync(buffer, 0, buffer.Length, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error reading from scale");
                await Task.Delay(100, ct);
                continue;
            }

            for (int i = 0; i < bytesRead; i++)
            {
                var b = buffer[i];
                if (b == '\n' || b == '\r')
                {
                    if (lineBuffer.Count > 0)
                    {
                        var line = System.Text.Encoding.ASCII.GetString(lineBuffer.ToArray());
                        if (TryParseReading(line, out var reading))
                        {
                            yield return reading;
                        }
                        lineBuffer.Clear();
                    }
                }
                else
                {
                    lineBuffer.Add(b);
                }
            }
        }
    }

    private static bool TryParseReading(string line, out ScaleReading reading)
    {
        reading = null!;

        var match = ScaleRegex().Match(line);
        if (!match.Success)
            return false;

        var valueStr = match.Groups["value"].Value;
        var unit = match.Groups["unit"].Value.ToLowerInvariant();
        var stable = match.Groups["stable"].Success || line.Contains("ST");

        if (!double.TryParse(valueStr, System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture, out var value))
            return false;

        reading = new ScaleReading(value, unit, stable, DateTime.UtcNow);
        return true;
    }

    [GeneratedRegex(@"(?<stable>ST)?.*?(?<value>[+-]?\d+\.?\d*)\s*(?<unit>kg|g|lb|oz)", RegexOptions.IgnoreCase)]
    private static partial Regex ScaleRegex();

    public ValueTask DisposeAsync()
    {
        DisconnectAsync().Wait();
        return ValueTask.CompletedTask;
    }
}
