// ============================================
// TITAN - Hardware Simulators
// ============================================
// File: tests/Titan.Simulators/ScaleSimulator.cs
// ============================================
using System.IO.Ports;
using System.Text;
using Microsoft.Extensions.Logging;

namespace Titan.Simulators;

public interface IScaleSimulator : IDisposable
{
    Task StartAsync(string portName, CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
    void SetWeight(double weight, bool stable = true);
    void SimulateRamp(double startWeight, double endWeight, double durationSeconds);
    void SimulateFluctuation(double baseWeight, double amplitude);
}

public sealed class ScaleSimulator : IScaleSimulator
{
    private readonly ILogger<ScaleSimulator> _logger;
    private SerialPort? _serialPort;
    private double _currentWeight = 0.0;
    private bool _isStable = true;
    private CancellationTokenSource? _cts;
    private Task? _transmissionTask;

    public ScaleSimulator(ILogger<ScaleSimulator> logger)
    {
        _logger = logger;
    }

    public async Task StartAsync(string portName, CancellationToken ct = default)
    {
        try
        {
            _serialPort = new SerialPort(portName)
            {
                BaudRate = 9600,
                Parity = Parity.None,
                DataBits = 8,
                StopBits = StopBits.One,
                WriteTimeout = 1000
            };

            _serialPort.Open();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            
            // Start continuous transmission
            _transmissionTask = TransmitLoopAsync(_cts.Token);
            
            _logger.LogInformation("Scale simulator started on {Port}", portName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start scale simulator");
            throw;
        }
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        _cts?.Cancel();
        _transmissionTask?.Wait(ct);
        
        _serialPort?.Close();
        _serialPort?.Dispose();
        
        _logger.LogInformation("Scale simulator stopped");
        return Task.CompletedTask;
    }

    public void SetWeight(double weight, bool stable = true)
    {
        _currentWeight = weight;
        _isStable = stable;
    }

    public async void SimulateRamp(double startWeight, double endWeight, double durationSeconds)
    {
        var steps = (int)(durationSeconds * 10); // 10 updates per second
        var stepWeight = (endWeight - startWeight) / steps;
        
        _isStable = false;
        
        for (int i = 0; i <= steps; i++)
        {
            _currentWeight = startWeight + stepWeight * i;
            await Task.Delay(100);
        }
        
        _isStable = true;
    }

    public void SimulateFluctuation(double baseWeight, double amplitude)
    {
        _ = Task.Run(async () =>
        {
            var random = new Random();
            _isStable = false;
            
            for (int i = 0; i < 50; i++)
            {
                var noise = (random.NextDouble() - 0.5) * 2 * amplitude;
                _currentWeight = baseWeight + noise;
                await Task.Delay(100);
            }
            
            _currentWeight = baseWeight;
            _isStable = true;
        });
    }

    private async Task TransmitLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var data = FormatWeightData(_currentWeight, _isStable);
                var bytes = Encoding.ASCII.GetBytes(data);
                
                _serialPort?.Write(bytes, 0, bytes.Length);
                
                await Task.Delay(100, ct); // 10Hz update rate
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error in transmit loop");
            }
        }
    }

    private static string FormatWeightData(double weight, bool stable)
    {
        var status = stable ? "ST" : "US";  // ST = Stable, US = Unstable
        return $"{status},GS,{weight,8:F3},kg\r\n";
    }

    public void Dispose()
    {
        StopAsync().Wait();
    }
}

// ============================================
// File: tests/Titan.Simulators/PrinterSimulator.cs
// ============================================
using System.IO;
using Microsoft.Extensions.Logging;

namespace Titan.Simulators;

public interface IPrinterSimulator : IDisposable
{
    Task StartAsync(string devicePath, CancellationToken ct = default);
    Task StopAsync(CancellationToken ct = default);
    event EventHandler<PrintJob>? OnPrintJobReceived;
    void SimulateError(bool paperOut = false, bool ribbonOut = false);
    PrintStatus GetStatus();
}

public class PrintJob
{
    public string Id { get; } = Guid.NewGuid().ToString("N")[..8];
    public string ZplData { get; set; } = "";
    public DateTime ReceivedAt { get; } = DateTime.UtcNow;
    public DateTime? CompletedAt { get; set; }
    public PrintStatus Status { get; set; } = PrintStatus.Pending;
}

public enum PrintStatus
{
    Pending,
    Printing,
    Completed,
    Error
}

public sealed class PrinterSimulator : IPrinterSimulator
{
    private readonly ILogger<PrinterSimulator> _logger;
    private readonly List<PrintJob> _jobs = new();
    private FileStream? _fileStream;
    private StreamReader? _reader;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private bool _paperOut = false;
    private bool _ribbonOut = false;

    public event EventHandler<PrintJob>? OnPrintJobReceived;

    public PrinterSimulator(ILogger<PrinterSimulator> logger)
    {
        _logger = logger;
    }

    public async Task StartAsync(string devicePath, CancellationToken ct = default)
    {
        try
        {
            // Create a named pipe or use a file for simulation
            if (File.Exists(devicePath))
            {
                File.Delete(devicePath);
            }

            // For simulation, we'll use a file that we monitor
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _listenTask = MonitorFileAsync(devicePath, _cts.Token);
            
            _logger.LogInformation("Printer simulator started on {Path}", devicePath);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to start printer simulator");
            throw;
        }
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        _cts?.Cancel();
        _listenTask?.Wait(ct);
        _fileStream?.Dispose();
        _reader?.Dispose();
        
        _logger.LogInformation("Printer simulator stopped");
        return Task.CompletedTask;
    }

    public void SimulateError(bool paperOut = false, bool ribbonOut = false)
    {
        _paperOut = paperOut;
        _ribbonOut = ribbonOut;
        
        _logger.LogWarning("Printer error simulated: PaperOut={PaperOut}, RibbonOut={RibbonOut}", 
            paperOut, ribbonOut);
    }

    public PrintStatus GetStatus()
    {
        if (_paperOut || _ribbonOut)
            return PrintStatus.Error;
        return PrintStatus.Ready;
    }

    public IReadOnlyList<PrintJob> GetJobs() => _jobs.AsReadOnly();

    private async Task MonitorFileAsync(string devicePath, CancellationToken ct)
    {
        // In real implementation, this would read from the actual device file
        // For simulation, we'll create a mechanism to inject test data
        
        while (!ct.IsCancellationRequested)
        {
            try
            {
                // Check if test data file exists
                var testFile = devicePath + ".test";
                if (File.Exists(testFile))
                {
                    var zpl = await File.ReadAllTextAsync(testFile, ct);
                    File.Delete(testFile);
                    
                    var job = new PrintJob { ZplData = zpl };
                    
                    if (_paperOut)
                    {
                        job.Status = PrintStatus.Error;
                    }
                    else
                    {
                        job.Status = PrintStatus.Completed;
                        job.CompletedAt = DateTime.UtcNow;
                    }
                    
                    _jobs.Add(job);
                    OnPrintJobReceived?.Invoke(this, job);
                    
                    _logger.LogInformation("Print job received: {JobId}, Status: {Status}", 
                        job.Id, job.Status);
                }
                
                await Task.Delay(100, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error monitoring printer");
            }
        }
    }

    public void Dispose()
    {
        StopAsync().Wait();
    }
}

// ============================================
// File: tests/Titan.Simulators/RfidSimulator.cs
// ============================================
using Microsoft.Extensions.Logging;

namespace Titan.Simulators;

public interface IRfidSimulator : IDisposable
{
    event EventHandler<TagReadEvent>? OnTagRead;
    void StartReading();
    void StopReading();
    void SimulateTagRead(string epc, int rssi = -65);
    void SimulateBulkRead(int count, string prefix = "E200");
}

public class TagReadEvent : EventArgs
{
    public string Epc { get; set; } = "";
    public int Rssi { get; set; }
    public int Antenna { get; set; }
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
}

public sealed class RfidSimulator : IRfidSimulator
{
    private readonly ILogger<RfidSimulator> _logger;
    private readonly Random _random = new();
    private bool _isReading = false;
    private CancellationTokenSource? _cts;
    private Task? _readTask;

    public event EventHandler<TagReadEvent>? OnTagRead;

    public RfidSimulator(ILogger<RfidSimulator> logger)
    {
        _logger = logger;
    }

    public void StartReading()
    {
        if (_isReading) return;
        
        _isReading = true;
        _cts = new CancellationTokenSource();
        _readTask = ReadLoopAsync(_cts.Token);
        
        _logger.LogInformation("RFID simulator started reading");
    }

    public void StopReading()
    {
        _isReading = false;
        _cts?.Cancel();
        _readTask?.Wait();
        
        _logger.LogInformation("RFID simulator stopped reading");
    }

    public void SimulateTagRead(string epc, int rssi = -65)
    {
        var evt = new TagReadEvent
        {
            Epc = epc,
            Rssi = rssi,
            Antenna = _random.Next(1, 5)
        };
        
        OnTagRead?.Invoke(this, evt);
        _logger.LogDebug("Tag read simulated: {Epc}", epc);
    }

    public void SimulateBulkRead(int count, string prefix = "E200")
    {
        _ = Task.Run(async () =>
        {
            for (int i = 0; i < count; i++)
            {
                var epc = $"{prefix}{i:D24}";
                SimulateTagRead(epc, _random.Next(-80, -40));
                await Task.Delay(_random.Next(10, 100));
            }
        });
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _isReading)
        {
            // Randomly simulate tag reads
            if (_random.NextDouble() < 0.3) // 30% chance per cycle
            {
                var epc = $"E200{Guid.NewGuid():N}"[..24].ToUpper();
                SimulateTagRead(epc);
            }
            
            await Task.Delay(100, ct);
        }
    }

    public void Dispose()
    {
        StopReading();
    }
}

// ============================================
// File: tests/Titan.Simulators/SimulationScenarioRunner.cs
// ============================================
using Microsoft.Extensions.Logging;
using Titan.Core.Services;
using Titan.Core.Fsm;

namespace Titan.Simulators;

public class SimulationScenario
{
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public Func<IServiceProvider, CancellationToken, Task> RunAsync { get; set; } = null!;
}

public class SimulationScenarioRunner
{
    private readonly ILogger<SimulationScenarioRunner> _logger;
    private readonly List<SimulationScenario> _scenarios = new();

    public SimulationScenarioRunner(ILogger<SimulationScenarioRunner> logger)
    {
        _logger = logger;
    }

    public void RegisterScenario(SimulationScenario scenario)
    {
        _scenarios.Add(scenario);
        _logger.LogInformation("Registered scenario: {Name}", scenario.Name);
    }

    public async Task RunScenarioAsync(string name, IServiceProvider services, CancellationToken ct = default)
    {
        var scenario = _scenarios.FirstOrDefault(s => s.Name == name);
        if (scenario == null)
        {
            throw new ArgumentException($"Scenario '{name}' not found");
        }

        _logger.LogInformation("Running scenario: {Name}", scenario.Name);
        _logger.LogInformation("Description: {Description}", scenario.Description);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        
        try
        {
            await scenario.RunAsync(services, ct);
            _logger.LogInformation("Scenario completed in {ElapsedMs}ms", sw.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Scenario failed after {ElapsedMs}ms", sw.ElapsedMilliseconds);
            throw;
        }
    }

    public static SimulationScenario CreateNormalBatchScenario()
    {
        return new SimulationScenario
        {
            Name = "NormalBatchCycle",
            Description = "Normal batch cycle with stable weight and successful print",
            RunAsync = async (services, ct) =>
            {
                var batchService = services.GetRequiredService<BatchProcessingService>();
                var scaleSim = services.GetRequiredService<IScaleSimulator>();
                var printerSim = services.GetRequiredService<IPrinterSimulator>();

                // Start batch
                batchService.StartBatch("SIM-BATCH-001", "PROD-001", 1.0);

                // Phase 1: Empty
                scaleSim.SetWeight(0.0, true);
                await Task.Delay(1000, ct);

                // Phase 2: Place product
                scaleSim.SimulateRamp(0.0, 2.5, 2.0);
                await Task.Delay(2500, ct);

                // Phase 3: Stabilize (should trigger print)
                scaleSim.SetWeight(2.5, true);
                await Task.Delay(3000, ct);

                // Verify print was triggered
                // ... assertions ...

                // Phase 4: Remove product
                scaleSim.SimulateRamp(2.5, 0.0, 1.0);
                await Task.Delay(1500, ct);

                batchService.StopBatch();
            }
        };
    }

    public static SimulationScenario CreateWeightFluctuationScenario()
    {
        return new SimulationScenario
        {
            Name = "WeightFluctuation",
            Description = "Weight fluctuation after lock should trigger reweigh",
            RunAsync = async (services, ct) =>
            {
                var batchService = services.GetRequiredService<BatchProcessingService>();
                var scaleSim = services.GetRequiredService<IScaleSimulator>();

                batchService.StartBatch("SIM-BATCH-002", "PROD-001", 1.0);

                // Stabilize
                scaleSim.SetWeight(2.5, true);
                await Task.Delay(3000, ct);

                // Wait for lock
                while (batchService.CurrentState != BatchProcessingState.Locked)
                {
                    await Task.Delay(100, ct);
                }

                // Simulate fluctuation
                scaleSim.SimulateFluctuation(3.5, 0.2);
                await Task.Delay(1000, ct);

                // Verify paused state
                if (batchService.CurrentState != BatchProcessingState.Paused)
                {
                    throw new Exception("Expected Paused state after fluctuation");
                }

                batchService.StopBatch();
            }
        };
    }

    public static SimulationScenario CreatePrinterErrorScenario()
    {
        return new SimulationScenario
        {
            Name = "PrinterError",
            Description = "Printer error should be handled gracefully",
            RunAsync = async (services, ct) =>
            {
                var batchService = services.GetRequiredService<BatchProcessingService>();
                var scaleSim = services.GetRequiredService<IScaleSimulator>();
                var printerSim = services.GetRequiredService<IPrinterSimulator>();

                // Simulate printer error
                printerSim.SimulateError(paperOut: true);

                batchService.StartBatch("SIM-BATCH-003", "PROD-001", 1.0);

                // Try to print
                scaleSim.SetWeight(2.5, true);
                await Task.Delay(5000, ct);

                // Verify error handling
                // ... assertions ...

                batchService.StopBatch();
            }
        };
    }
}
