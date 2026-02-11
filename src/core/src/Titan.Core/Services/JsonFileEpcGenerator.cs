using System.Text.Json;
using Microsoft.Extensions.Logging;
using Titan.Domain.ValueObjects;

namespace Titan.Core.Services;

/// <summary>
/// Thread-safe EPC generator that stores counter in a JSON file.
/// No database dependency — instant EPC generation.
/// </summary>
public sealed class JsonFileEpcGenerator : IEpcGenerator
{
    private readonly string _filePath;
    private readonly string _prefix;
    private readonly ILogger<JsonFileEpcGenerator>? _logger;
    private readonly object _lock = new();
    private long _counter;

    public JsonFileEpcGenerator(
        string dataDir,
        string prefix = "3034257BF7194E4",
        ILogger<JsonFileEpcGenerator>? logger = null)
    {
        _prefix = prefix;
        _logger = logger;
        _filePath = Path.Combine(dataDir, "epc-counter.json");

        Directory.CreateDirectory(dataDir);
        _counter = LoadCounter();
        _logger?.LogInformation("EPC generator initialized: counter={Counter}, file={File}", _counter, _filePath);
    }

    public Task<string> GenerateNextAsync()
    {
        long next;
        lock (_lock)
        {
            next = ++_counter;
            SaveCounter(next);
        }

        var epc = EpcCode.Create(_prefix, next);
        return Task.FromResult(epc.Value);
    }

    public Task<long> GetCurrentCounterAsync()
    {
        lock (_lock)
        {
            return Task.FromResult(_counter);
        }
    }

    private long LoadCounter()
    {
        try
        {
            if (File.Exists(_filePath))
            {
                var json = File.ReadAllText(_filePath);
                var data = JsonSerializer.Deserialize<EpcState>(json);
                return data?.Counter ?? 0;
            }
        }
        catch (Exception ex)
        {
            _logger?.LogWarning(ex, "Failed to load EPC counter from {File}, starting from 0", _filePath);
        }
        return 0;
    }

    private void SaveCounter(long value)
    {
        try
        {
            var json = JsonSerializer.Serialize(new EpcState
            {
                Prefix = _prefix,
                Counter = value,
                UpdatedAt = DateTime.UtcNow
            });
            File.WriteAllText(_filePath, json);
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "Failed to save EPC counter to {File}", _filePath);
        }
    }

    private sealed class EpcState
    {
        public string Prefix { get; set; } = "";
        public long Counter { get; set; }
        public DateTime UpdatedAt { get; set; }
    }
}
