// ============================================
// TITAN CORE - Monitoring & Observability
// ============================================
// File: src/Titan.Core/Telemetry/MetricsService.cs
// ============================================
using System.Diagnostics.Metrics;
using Microsoft.Extensions.Logging;
using Titan.Core.Fsm;

namespace Titan.Core.Telemetry;

public interface IMetricsService
{
    void RecordWeightSample(double weight, string unit);
    void RecordStateTransition(BatchProcessingState fromState, BatchProcessingState toState);
    void RecordPrintJob(string epcCode, double weight, bool success);
    void RecordErpSync(bool success, TimeSpan duration);
    void RecordHardwareEvent(string deviceType, string eventType);
    void UpdateQueueDepth(int depth);
    void UpdateDeviceStatus(string status);
}

public sealed class MetricsService : IMetricsService
{
    private readonly ILogger<MetricsService> _logger;
    
    // Meters for OpenTelemetry
    private readonly Meter _titanMeter;
    
    // Counters
    private readonly Counter<long> _weightSamplesCounter;
    private readonly Counter<long> _stateTransitionsCounter;
    private readonly Counter<long> _printJobsCounter;
    private readonly Counter<long> _printJobsFailedCounter;
    private readonly Counter<long> _erpSyncCounter;
    private readonly Counter<long> _erpSyncFailedCounter;
    private readonly Counter<long> _hardwareEventsCounter;
    
    // Histograms
    private readonly Histogram<double> _weightHistogram;
    private readonly Histogram<double> _printDurationHistogram;
    private readonly Histogram<double> _erpSyncDurationHistogram;
    
    // Gauges
    private readonly ObservableGauge<int> _queueDepthGauge;
    private readonly ObservableGauge<int> _deviceStatusGauge;
    
    private int _currentQueueDepth;
    private string _currentDeviceStatus = "idle";

    public MetricsService(ILogger<MetricsService> logger)
    {
        _logger = logger;
        _titanMeter = new Meter("Titan.Core", "1.0.0");
        
        // Initialize counters
        _weightSamplesCounter = _titanMeter.CreateCounter<long>(
            "titan.weight.samples.total",
            description: "Total number of weight samples processed");
        
        _stateTransitionsCounter = _titanMeter.CreateCounter<long>(
            "titan.fsm.transitions.total",
            description: "Total number of FSM state transitions");
        
        _printJobsCounter = _titanMeter.CreateCounter<long>(
            "titan.print.jobs.total",
            description: "Total number of print jobs");
        
        _printJobsFailedCounter = _titanMeter.CreateCounter<long>(
            "titan.print.jobs.failed.total",
            description: "Total number of failed print jobs");
        
        _erpSyncCounter = _titanMeter.CreateCounter<long>(
            "titan.erp.sync.total",
            description: "Total number of ERP sync attempts");
        
        _erpSyncFailedCounter = _titanMeter.CreateCounter<long>(
            "titan.erp.sync.failed.total",
            description: "Total number of failed ERP syncs");
        
        _hardwareEventsCounter = _titanMeter.CreateCounter<long>(
            "titan.hardware.events.total",
            description: "Total number of hardware events");
        
        // Initialize histograms
        _weightHistogram = _titanMeter.CreateHistogram<double>(
            "titan.weight.distribution",
            unit: "kg",
            description: "Distribution of measured weights");
        
        _printDurationHistogram = _titanMeter.CreateHistogram<double>(
            "titan.print.duration",
            unit: "ms",
            description: "Print job duration in milliseconds");
        
        _erpSyncDurationHistogram = _titanMeter.CreateHistogram<double>(
            "titan.erp.sync.duration",
            unit: "ms",
            description: "ERP sync duration in milliseconds");
        
        // Initialize gauges
        _queueDepthGauge = _titanMeter.CreateObservableGauge(
            "titan.queue.depth",
            () => _currentQueueDepth,
            description: "Current queue depth");
        
        _deviceStatusGauge = _titanMeter.CreateObservableGauge(
            "titan.device.status",
            () => GetDeviceStatusValue(),
            description: "Device status (0=idle, 1=running, 2=paused, 3=error)");
        
        _logger.LogInformation("Metrics service initialized");
    }

    public void RecordWeightSample(double weight, string unit)
    {
        _weightSamplesCounter.Add(1, new KeyValuePair<string, object?>("unit", unit));
        _weightHistogram.Record(weight, new KeyValuePair<string, object?>("unit", unit));
    }

    public void RecordStateTransition(BatchProcessingState fromState, BatchProcessingState toState)
    {
        _stateTransitionsCounter.Add(1, 
            new KeyValuePair<string, object?>("from", fromState.ToString()),
            new KeyValuePair<string, object?>("to", toState.ToString()));
        
        _logger.LogDebug("State transition: {From} -> {To}", fromState, toState);
    }

    public void RecordPrintJob(string epcCode, double weight, bool success)
    {
        if (success)
        {
            _printJobsCounter.Add(1, new KeyValuePair<string, object?>("epc", epcCode));
        }
        else
        {
            _printJobsFailedCounter.Add(1);
        }
        
        _logger.LogInformation("Print job: {Epc}, Weight: {Weight}, Success: {Success}", 
            epcCode, weight, success);
    }

    public void RecordPrintDuration(TimeSpan duration)
    {
        _printDurationHistogram.Record(duration.TotalMilliseconds);
    }

    public void RecordErpSync(bool success, TimeSpan duration)
    {
        if (success)
        {
            _erpSyncCounter.Add(1);
        }
        else
        {
            _erpSyncFailedCounter.Add(1);
        }
        
        _erpSyncDurationHistogram.Record(duration.TotalMilliseconds,
            new KeyValuePair<string, object?>("success", success.ToString()));
    }

    public void RecordHardwareEvent(string deviceType, string eventType)
    {
        _hardwareEventsCounter.Add(1,
            new KeyValuePair<string, object?>("device", deviceType),
            new KeyValuePair<string, object?>("event", eventType));
    }

    public void UpdateQueueDepth(int depth)
    {
        _currentQueueDepth = depth;
    }

    public void UpdateDeviceStatus(string status)
    {
        _currentDeviceStatus = status.ToLower();
    }

    private int GetDeviceStatusValue()
    {
        return _currentDeviceStatus switch
        {
            "idle" => 0,
            "running" or "online" => 1,
            "paused" or "busy" => 2,
            "error" or "offline" => 3,
            _ => 0
        };
    }
}

// ============================================
// File: src/Titan.Core/Telemetry/TracingService.cs
// ============================================
using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace Titan.Core.Telemetry;

public interface ITracingService
{
    Activity? StartActivity(string name, ActivityKind kind = ActivityKind.Internal);
    void RecordException(Activity? activity, Exception ex);
    void AddEvent(Activity? activity, string eventName, Dictionary<string, object>? tags = null);
}

public sealed class TracingService : ITracingService
{
    private readonly ILogger<TracingService> _logger;
    private readonly ActivitySource _activitySource;

    public TracingService(ILogger<TracingService> logger)
    {
        _logger = logger;
        _activitySource = new ActivitySource("Titan.Core", "1.0.0");
    }

    public Activity? StartActivity(string name, ActivityKind kind = ActivityKind.Internal)
    {
        var activity = _activitySource.StartActivity(name, kind);
        
        if (activity != null)
        {
            _logger.LogDebug("Started activity: {ActivityName}, TraceId: {TraceId}", 
                name, activity.TraceId);
        }
        
        return activity;
    }

    public void RecordException(Activity? activity, Exception ex)
    {
        if (activity == null) return;
        
        activity.SetStatus(ActivityStatusCode.Error, ex.Message);
        activity.RecordException(ex);
        
        _logger.LogError(ex, "Exception recorded in trace: {ActivityName}", activity.OperationName);
    }

    public void AddEvent(Activity? activity, string eventName, Dictionary<string, object>? tags = null)
    {
        if (activity == null) return;
        
        var activityTags = tags?.Select(t => new KeyValuePair<string, object?>(t.Key, t.Value))
                               .ToArray() ?? Array.Empty<KeyValuePair<string, object?>>();
        
        activity.AddEvent(new ActivityEvent(eventName, tags: new ActivityTagsCollection(activityTags)));
    }
}

// ============================================
// File: src/Titan.Infrastructure/Telemetry/PrometheusExporter.cs
// ============================================
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using System.Diagnostics.Metrics;

namespace Titan.Infrastructure.Telemetry;

public static class PrometheusExtensions
{
    public static IServiceCollection AddPrometheusMetrics(this IServiceCollection services)
    {
        services.AddSingleton<PrometheusMetricCollector>();
        services.AddHostedService(sp => sp.GetRequiredService<PrometheusMetricCollector>());
        return services;
    }

    public static IEndpointRouteBuilder MapPrometheusScrapeEndpoint(this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapGet("/metrics", async (PrometheusMetricCollector collector, HttpContext context) =>
        {
            var metrics = collector.GetMetrics();
            context.Response.ContentType = "text/plain; version=0.0.4; charset=utf-8";
            await context.Response.WriteAsync(metrics);
        });
        return endpoints;
    }
}

public sealed class PrometheusMetricCollector : IHostedService
{
    private readonly MeterListener _meterListener;
    private readonly Dictionary<string, MetricValue> _metrics = new();
    private readonly Lock _lock = new();

    public PrometheusMetricCollector()
    {
        _meterListener = new MeterListener();
        _meterListener.SetMeasurementEventCallback<double>(OnMeasurementRecorded);
        _meterListener.SetMeasurementEventCallback<long>(OnMeasurementRecorded);
        _meterListener.SetMeasurementEventCallback<int>(OnMeasurementRecorded);
    }

    private void OnMeasurementRecorded<T>(Instrument instrument, T measurement, ReadOnlySpan<KeyValuePair<string, object?>> tags, object? state)
        where T : struct
    {
        var metricName = instrument.Name.Replace('.', '_');
        var tagString = FormatTags(tags);
        var key = $"{metricName}{tagString}";

        lock (_lock)
        {
            if (!_metrics.TryGetValue(key, out var metricValue))
            {
                metricValue = new MetricValue
                {
                    Name = metricName,
                    Description = instrument.Description,
                    Type = GetMetricType(instrument),
                    Tags = tags.ToArray().ToDictionary(t => t.Key, t => t.Value?.ToString() ?? "")
                };
                _metrics[key] = metricValue;
            }

            metricValue.Value = Convert.ToDouble(measurement);
            metricValue.LastUpdated = DateTime.UtcNow;
        }
    }

    public string GetMetrics()
    {
        var sb = new StringBuilder();
        
        lock (_lock)
        {
            foreach (var metric in _metrics.Values.GroupBy(m => m.Name))
            {
                var first = metric.First();
                sb.AppendLine($"# HELP {first.Name} {first.Description}");
                sb.AppendLine($"# TYPE {first.Name} {first.Type}");

                foreach (var instance in metric)
                {
                    var tags = FormatPrometheusTags(instance.Tags);
                    sb.AppendLine($"{first.Name}{tags} {instance.Value:F6}");
                }
                
                sb.AppendLine();
            }
        }

        return sb.ToString();
    }

    private static string GetMetricType(Instrument instrument)
    {
        return instrument switch
        {
            Counter<int> or Counter<long> or Counter<double> => "counter",
            Histogram<int> or Histogram<long> or Histogram<double> => "histogram",
            ObservableGauge<int> or ObservableGauge<long> or ObservableGauge<double> => "gauge",
            _ => "unknown"
        };
    }

    private static string FormatTags(ReadOnlySpan<KeyValuePair<string, object?>> tags)
    {
        if (tags.IsEmpty) return "";
        
        var tagStrings = new List<string>();
        foreach (var tag in tags)
        {
            tagStrings.Add($"{tag.Key}={tag.Value}");
        }
        return "{" + string.Join(",", tagStrings) + "}";
    }

    private static string FormatPrometheusTags(Dictionary<string, string> tags)
    {
        if (tags.Count == 0) return "";
        
        var tagStrings = tags.Select(t => $"{t.Key}=\"{t.Value}\"");
        return "{" + string.Join(",", tagStrings) + "}";
    }

    public Task StartAsync(CancellationToken ct)
    {
        _meterListener.Start();
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct)
    {
        _meterListener.Dispose();
        return Task.CompletedTask;
    }

    private class MetricValue
    {
        public string Name { get; set; } = "";
        public string Description { get; set; } = "";
        public string Type { get; set; } = "";
        public double Value { get; set; }
        public Dictionary<string, string> Tags { get; set; } = new();
        public DateTime LastUpdated { get; set; }
    }
}

// ============================================
// File: src/Titan.Infrastructure/Telemetry/OpenTelemetryConfig.cs
// ============================================
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Configuration;

namespace Titan.Infrastructure.Telemetry;

public static class OpenTelemetryConfig
{
    public static IServiceCollection AddTitanTelemetry(
        this IServiceCollection services, 
        IConfiguration configuration)
    {
        var serviceName = configuration.GetValue("OTEL_SERVICE_NAME", "titan-core");
        var otlpEndpoint = configuration.GetValue("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317");

        services.AddOpenTelemetry()
            .WithTracing(tracing =>
            {
                tracing
                    .SetResourceBuilder(ResourceBuilder.CreateDefault()
                        .AddService(serviceName, serviceVersion: "1.0.0"))
                    .AddSource("Titan.Core")
                    .AddSource("System.Net.Http")
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddOtlpExporter(options =>
                    {
                        options.Endpoint = new Uri(otlpEndpoint);
                    })
                    .AddConsoleExporter(); // For development
            })
            .WithMetrics(metrics =>
            {
                metrics
                    .SetResourceBuilder(ResourceBuilder.CreateDefault()
                        .AddService(serviceName, serviceVersion: "1.0.0"))
                    .AddMeter("Titan.Core")
                    .AddMeter("System.Net.Http")
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddPrometheusExporter()
                    .AddOtlpExporter(options =>
                    {
                        options.Endpoint = new Uri(otlpEndpoint);
                    });
            });

        return services;
    }
}

// ============================================
// File: src/Titan.Host/HealthChecks/DatabaseHealthCheck.cs
// ============================================
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.EntityFrameworkCore;
using Titan.Infrastructure.Persistence;

namespace Titan.Host.HealthChecks;

public class DatabaseHealthCheck : IHealthCheck
{
    private readonly TitanDbContext _dbContext;
    private readonly ILogger<DatabaseHealthCheck> _logger;

    public DatabaseHealthCheck(TitanDbContext dbContext, ILogger<DatabaseHealthCheck> logger)
    {
        _dbContext = dbContext;
        _logger = logger;
    }

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, 
        CancellationToken ct = default)
    {
        try
        {
            await _dbContext.Database.ExecuteSqlRawAsync("SELECT 1", ct);
            return HealthCheckResult.Healthy("Database connection is healthy");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Database health check failed");
            return HealthCheckResult.Unhealthy("Database connection failed", ex);
        }
    }
}

// ============================================
// File: src/Titan.Host/HealthChecks/HardwareHealthCheck.cs
// ============================================
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Titan.Infrastructure.Hardware.Scale;
using Titan.Infrastructure.Hardware.Printer;

namespace Titan.Host.HealthChecks;

public class HardwareHealthCheck : IHealthCheck
{
    private readonly IScalePort _scalePort;
    private readonly IPrinterTransport _printerTransport;
    private readonly ILogger<HardwareHealthCheck> _logger;

    public HardwareHealthCheck(
        IScalePort scalePort, 
        IPrinterTransport printerTransport,
        ILogger<HardwareHealthCheck> logger)
    {
        _scalePort = scalePort;
        _printerTransport = printerTransport;
        _logger = logger;
    }

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, 
        CancellationToken ct = default)
    {
        var checks = new Dictionary<string, object>();
        var status = HealthStatus.Healthy;

        // Check scale
        checks["scale_connected"] = _scalePort.IsConnected;
        if (!_scalePort.IsConnected)
        {
            status = HealthStatus.Degraded;
        }

        // Check printer
        checks["printer_connected"] = _printerTransport.IsConnected;
        if (!_printerTransport.IsConnected)
        {
            status = HealthStatus.Degraded;
        }

        var description = status == HealthStatus.Healthy 
            ? "All hardware is connected" 
            : "Some hardware is not connected";

        return Task.FromResult(new HealthCheckResult(status, description, data: checks));
    }
}

// ============================================
// File: src/Titan.Host/HealthChecks/ElixirBridgeHealthCheck.cs
// ============================================
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Titan.Infrastructure.Messaging;

namespace Titan.Host.HealthChecks;

public class ElixirBridgeHealthCheck : IHealthCheck
{
    private readonly IElixirBridgeClient _bridgeClient;
    private readonly ILogger<ElixirBridgeHealthCheck> _logger;

    public ElixirBridgeHealthCheck(IElixirBridgeClient bridgeClient, ILogger<ElixirBridgeHealthCheck> logger)
    {
        _bridgeClient = bridgeClient;
        _logger = logger;
    }

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, 
        CancellationToken ct = default)
    {
        if (_bridgeClient.IsConnected)
        {
            return Task.FromResult(HealthCheckResult.Healthy("Elixir Bridge is connected"));
        }
        else
        {
            return Task.FromResult(HealthCheckResult.Degraded("Elixir Bridge is not connected"));
        }
    }
}
