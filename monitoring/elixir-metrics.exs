# ============================================
# TITAN BRIDGE - Monitoring & Observability
# ============================================
# File: titan_bridge/lib/titan_bridge/telemetry/telemetry.ex
# ============================================
defmodule TitanBridge.Telemetry do
  @moduledoc """
  Telemetry events and metrics for Titan Bridge.
  """
  
  import Telemetry.Metrics

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Custom Application Metrics
      counter("titan.device.connections.total",
        tags: [:device_id, :status]
      ),
      last_value("titan.device.connections.active"),
      
      counter("titan.websocket.messages.received.total",
        tags: [:message_type]
      ),
      counter("titan.websocket.messages.sent.total",
        tags: [:message_type]
      ),
      summary("titan.websocket.message.processing.duration",
        unit: {:native, :millisecond}
      ),

      counter("titan.queue.messages.enqueued.total",
        tags: [:record_type, :priority]
      ),
      counter("titan.queue.messages.completed.total",
        tags: [:record_type]
      ),
      counter("titan.queue.messages.failed.total",
        tags: [:record_type]
      ),
      last_value("titan.queue.depth"),
      summary("titan.queue.processing.duration",
        unit: {:native, :millisecond}
      ),

      counter("titan.erp.sync.requests.total",
        tags: [:endpoint, :status]
      ),
      summary("titan.erp.sync.duration",
        unit: {:native, :millisecond},
        tags: [:endpoint]
      ),

      counter("titan.telegram.commands.total",
        tags: [:command]
      ),
      counter("titan.telegram.callbacks.total",
        tags: [:action]
      ),
      summary("titan.telegram.response.duration",
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("titan.repo.query.total_time", unit: {:native, :millisecond}),
      summary("titan.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("titan.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("titan.repo.query.idle_time", unit: {:native, :millisecond}),
    ]
  end

  @doc """
  Returns a list of periodic measurements.
  """
  def periodic_measurements do
    [
      # VM Metrics
      {TitanBridge.Telemetry.VM, :memory, []},
      {TitanBridge.Telemetry.VM, :run_queue_lengths, []},
      
      # Application Metrics
      {TitanBridge.Telemetry.App, :device_stats, []},
      {TitanBridge.Telemetry.App, :queue_stats, []},
    ]
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge/telemetry/vm.ex
# ============================================
defmodule TitanBridge.Telemetry.VM do
  @moduledoc """
  VM telemetry measurements.
  """

  def memory do
    memory = :erlang.memory()

    :telemetry.execute(
      [:vm, :memory],
      %{
        total: memory[:total],
        processes: memory[:processes],
        processes_used: memory[:processes_used],
        system: memory[:system],
        atom: memory[:atom],
        atom_used: memory[:atom_used],
        binary: memory[:binary],
        code: memory[:code],
        ets: memory[:ets]
      }
    )
  end

  def run_queue_lengths do
    %{
      cpu: cpu,
      io: io,
      total: total
    } = :erlang.statistics(:run_queue_lengths)

    :telemetry.execute(
      [:vm, :total_run_queue_lengths],
      %{
        total: total,
        cpu: cpu,
        io: io
      }
    )
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge/telemetry/app.ex
# ============================================
defmodule TitanBridge.Telemetry.App do
  @moduledoc """
  Application-specific telemetry measurements.
  """
  
  alias TitanBridge.DeviceRegistry
  alias TitanBridge.MessageQueue

  def device_stats do
    devices = DeviceRegistry.list_all()
    
    by_status = Enum.group_by(devices, & &1.status)
    
    :telemetry.execute(
      [:titan, :device, :connections],
      %{
        active: length(devices),
        online: length(Map.get(by_status, :online, [])),
        offline: length(Map.get(by_status, :offline, [])),
        busy: length(Map.get(by_status, :busy, [])),
        error: length(Map.get(by_status, :error, []))
      }
    )
  end

  def queue_stats do
    stats = MessageQueue.stats()
    
    :telemetry.execute(
      [:titan, :queue],
      %{
        depth: stats.pending + stats.processing,
        pending: stats.pending,
        processing: stats.processing
      }
    )
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge/telemetry/metrics_exporter.ex
# ============================================
defmodule TitanBridge.Telemetry.MetricsExporter do
  @moduledoc """
  Prometheus-compatible metrics exporter.
  """
  
  use Prometheus.Metric

  # Counters
  defsetup do
    Counter.declare(
      name: :titan_device_connections_total,
      help: "Total number of device connections",
      labels: [:device_id, :status]
    )
    
    Counter.declare(
      name: :titan_websocket_messages_received_total,
      help: "Total WebSocket messages received",
      labels: [:message_type]
    )
    
    Counter.declare(
      name: :titan_websocket_messages_sent_total,
      help: "Total WebSocket messages sent",
      labels: [:message_type]
    )
    
    Counter.declare(
      name: :titan_queue_messages_enqueued_total,
      help: "Total messages enqueued",
      labels: [:record_type]
    )
    
    Counter.declare(
      name: :titan_erp_sync_requests_total,
      help: "Total ERP sync requests",
      labels: [:endpoint, :status]
    )

    # Gauges
    Gauge.declare(
      name: :titan_device_connections_active,
      help: "Active device connections"
    )
    
    Gauge.declare(
      name: :titan_queue_depth,
      help: "Current queue depth"
    )
    
    Gauge.declare(
      name: :titan_telegram_sessions_active,
      help: "Active Telegram sessions"
    )

    # Histograms
    Histogram.declare(
      name: :titan_websocket_message_processing_duration_seconds,
      help: "WebSocket message processing duration",
      buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0]
    )
    
    Histogram.declare(
      name: :titan_erp_sync_duration_seconds,
      help: "ERP sync duration",
      buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0]
    )
  end

  def export do
    Prometheus.TextFormat.generate()
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge_web/controllers/metrics_controller.ex
# ============================================
defmodule TitanBridgeWeb.MetricsController do
  use TitanBridgeWeb, :controller
  
  alias TitanBridge.Telemetry.MetricsExporter

  def index(conn, _params) do
    metrics = MetricsExporter.export()
    
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge_web/controllers/health_controller.ex
# ============================================
defmodule TitanBridgeWeb.HealthController do
  use TitanBridgeWeb, :controller
  
  alias TitanBridge.DeviceRegistry
  alias TitanBridge.Repo

  def index(conn, _params) do
    checks = %{
      "database" => check_database(),
      "device_registry" => check_device_registry(),
      "message_queue" => check_message_queue()
    }
    
    all_healthy = Enum.all?(checks, fn {_, status} -> status == "ok" end)
    
    status_code = if all_healthy, do: 200, else: 503
    
    conn
    |> put_status(status_code)
    |> json(%{
      status: if(all_healthy, do: "healthy", else: "unhealthy"),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: checks
    })
  end

  def ready(conn, _params) do
    # Check if ready to receive traffic
    conn
    |> json(%{
      ready: true,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def live(conn, _params) do
    # Simple liveness check
    send_resp(conn, 200, "OK")
  end

  defp check_database do
    try do
      Ecto.Adapters.SQL.query!(Repo, "SELECT 1")
      "ok"
    rescue
      _ -> "error"
    end
  end

  defp check_device_registry do
    # Check if registry process is alive
    case Process.whereis(TitanBridge.DeviceRegistry) do
      nil -> "error"
      pid -> if Process.alive?(pid), do: "ok", else: "error"
    end
  end

  defp check_message_queue do
    case Process.whereis(TitanBridge.MessageQueue) do
      nil -> "error"
      pid -> if Process.alive?(pid), do: "ok", else: "error"
    end
  end
end

# ============================================
# File: titan_bridge/lib/titan_bridge/open_telemetry.ex
# ============================================
defmodule TitanBridge.OpenTelemetry do
  @moduledoc """
  OpenTelemetry configuration and helpers.
  """
  
  require OpenTelemetry.Tracer

  def setup do
    :opentelemetry_cowboy.setup()
    OpentelemetryPhoenix.setup()
    OpentelemetryEcto.setup([:titan_bridge, :repo])
  end

  def trace(name, attributes \\ %{}, fun) do
    OpenTelemetry.Tracer.with_span name, attributes: attributes do
      fun.()
    end
  end

  def add_event(name, attributes \\ %{}) do
    OpenTelemetry.Tracer.add_event(name, attributes)
  end

  def set_attribute(key, value) do
    OpenTelemetry.Tracer.set_attribute(key, value)
  end

  def record_exception(exception, stacktrace \\ nil) do
    OpenTelemetry.Tracer.record_exception(exception, stacktrace)
  end
end

# ============================================
# File: titan_bridge/config/runtime.exs (Monitoring additions)
# ============================================
# Add to existing runtime.exs:

# OpenTelemetry configuration
config :opentelemetry,
  resource: [
    service: [
      name: System.get_env("OTEL_SERVICE_NAME", "titan-bridge"),
      version: "1.0.0",
      namespace: "titan"
    ]
  ],
  span_processor: :batch,
  exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

# Prometheus metrics endpoint
config :titan_bridge, TitanBridgeWeb.Endpoint,
  instrumenters: [Prometheus.PhoenixInstrumenter]

config :prometheus, TitanBridgeWeb.Endpoint.MetricsExporter,
  path: "/metrics",
  format: :text

# Telemetry polling interval
config :titan_bridge, :telemetry,
  vm_metrics_interval: 15_000,  # 15 seconds
  app_metrics_interval: 30_000   # 30 seconds
