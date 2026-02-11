using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Titan.Core.Services;

/// <summary>
/// Appends weight records to a JSON Lines (.jsonl) file.
/// No database — instant writes. Records are synced to PostgreSQL periodically.
/// </summary>
public sealed class JsonFileRecordStore
{
    private readonly string _filePath;
    private readonly string _syncedDir;
    private readonly ILogger<JsonFileRecordStore>? _logger;
    private readonly object _lock = new();

    public JsonFileRecordStore(string dataDir, ILogger<JsonFileRecordStore>? logger = null)
    {
        _logger = logger;
        _filePath = Path.Combine(dataDir, "weight-records.jsonl");
        _syncedDir = Path.Combine(dataDir, "synced");

        Directory.CreateDirectory(dataDir);
        Directory.CreateDirectory(_syncedDir);
    }

    public void Append(WeightRecordEntry record)
    {
        lock (_lock)
        {
            try
            {
                var json = JsonSerializer.Serialize(record);
                File.AppendAllText(_filePath, json + "\n");
            }
            catch (Exception ex)
            {
                _logger?.LogError(ex, "Failed to write record to {File}", _filePath);
            }
        }
    }

    /// <summary>
    /// Reads all pending (unsynced) records and rotates the file.
    /// Returns empty list if no records or on error.
    /// </summary>
    public List<WeightRecordEntry> TakeAllPending()
    {
        lock (_lock)
        {
            try
            {
                if (!File.Exists(_filePath))
                    return [];

                var lines = File.ReadAllLines(_filePath);
                if (lines.Length == 0)
                    return [];

                var records = new List<WeightRecordEntry>();
                foreach (var line in lines)
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    try
                    {
                        var record = JsonSerializer.Deserialize<WeightRecordEntry>(line);
                        if (record != null) records.Add(record);
                    }
                    catch
                    {
                        _logger?.LogWarning("Skipping malformed record line");
                    }
                }

                // Rotate: move current file to synced dir, create new empty file
                var rotatedPath = Path.Combine(_syncedDir, $"records-{DateTime.UtcNow:yyyyMMdd-HHmmss-fff}.jsonl");
                File.Move(_filePath, rotatedPath);

                _logger?.LogInformation("Rotated {Count} records to {File}", records.Count, rotatedPath);
                return records;
            }
            catch (Exception ex)
            {
                _logger?.LogError(ex, "Failed to read pending records");
                return [];
            }
        }
    }

    public int PendingCount
    {
        get
        {
            lock (_lock)
            {
                try
                {
                    if (!File.Exists(_filePath)) return 0;
                    return File.ReadAllLines(_filePath).Count(l => !string.IsNullOrWhiteSpace(l));
                }
                catch { return 0; }
            }
        }
    }
}

public sealed class WeightRecordEntry
{
    public string BatchId { get; set; } = "";
    public string ProductId { get; set; } = "";
    public double Weight { get; set; }
    public string Unit { get; set; } = "kg";
    public string EpcCode { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public bool Synced { get; set; }
}
