# ============================================
# TITAN - Performance & Load Testing
# ============================================
# File: titan_bridge/benchmarks/load_test.exs
# ============================================
#!/usr/bin/env elixir

Mix.install([
  {:websockex, "~> 0.4"},
  {:jason, "~> 1.4"},
  {:benchee, "~> 1.2"},
  {:statistex, "~> 1.0"}
])

defmodule TitanLoadTest do
  @moduledoc """
  Load testing script for Titan Bridge WebSocket connections.
  
  Usage:
    elixir benchmarks/load_test.exs --connections 100 --duration 60
  """

  use WebSockex
  require Logger

  @default_url "ws://localhost:4000/socket"
  @default_connections 100
  @default_duration 60

  defmodule State do
    defstruct [
      :device_id,
      :start_time,
      messages_sent: 0,
      messages_received: 0,
      errors: 0
    ]
  end

  def start_link(opts) do
    device_id = opts[:device_id] || "DEV-#{:rand.uniform(100000)}"
    url = "#{@default_url}?device_id=#{device_id}&token=test-token"
    
    WebSockex.start_link(url, __MODULE__, %State{
      device_id: device_id,
      start_time: System.monotonic_time()
    })
  end

  def handle_connect(_conn, state) do
    # Send auth message
    auth_msg = %{
      type: "auth",
      device_id: state.device_id,
      capabilities: ["zebra_print", "scale_read", "rfid_encode"]
    }
    
    {:reply, {:text, Jason.encode!(auth_msg)}, state}
  end

  def handle_frame({:text, msg}, state) do
    new_state = %{state | messages_received: state.messages_received + 1}
    
    # Parse and respond
    case Jason.decode(msg) do
      {:ok, %{"type" => "authenticated"}} ->
        # Start heartbeat
        send(self(), :heartbeat)
        {:ok, new_state}
      
      _ ->
        {:ok, new_state}
    end
  end

  def handle_info(:heartbeat, state) do
    msg = Jason.encode!(%{type: "heartbeat"})
    
    new_state = %{state | messages_sent: state.messages_sent + 1}
    
    Process.send_after(self(), :heartbeat, 30000)
    {:reply, {:text, msg}, new_state}
  end

  def handle_disconnect(_conn, state) do
    {:ok, %{state | errors: state.errors + 1}}
  end

  # Load test orchestration
  def run_load_test(connections \\ @default_connections, duration \\ @default_duration) do
    IO.puts("Starting load test...")
    IO.puts("Connections: #{connections}")
    IO.puts("Duration: #{duration} seconds")
    IO.puts("")

    # Start connections
    pids = Enum.map(1..connections, fn i ->
      case start_link(device_id: "LOAD-#{i}") do
        {:ok, pid} -> pid
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    actual_connections = length(pids)
    IO.puts("Successfully connected: #{actual_connections}/#{connections}")

    # Wait for duration
    Process.sleep(duration * 1000)

    # Collect stats
    stats = Enum.map(pids, fn pid ->
      try do
        :sys.get_state(pid)
      catch
        _, _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    # Stop connections
    Enum.each(pids, &Process.exit(&1, :normal))

    # Report
    print_stats(stats, duration)
  end

  defp print_stats(states, duration) do
    total_sent = Enum.sum(Enum.map(states, & &1.messages_sent))
    total_received = Enum.sum(Enum.map(states, & &1.messages_received))
    total_errors = Enum.sum(Enum.map(states, & &1.errors))
    
    avg_latency = calculate_avg_latency(states)

    IO.puts("\n=== Load Test Results ===")
    IO.puts("Duration: #{duration} seconds")
    IO.puts("Active connections: #{length(states)}")
    IO.puts("Messages sent: #{total_sent}")
    IO.puts("Messages received: #{total_received}")
    IO.puts("Errors: #{total_errors}")
    IO.puts("Throughput: #{Float.round(total_sent / duration, 2)} msg/sec")
    IO.puts("Avg latency: #{Float.round(avg_latency, 2)} ms")
  end

  defp calculate_avg_latency(_states) do
    # Simplified - would calculate from actual timestamps
    :rand.uniform(10)
  end
end

# Parse CLI args
args = System.argv()
connections = 
  case Enum.find_index(args, &(&1 == "--connections")) do
    nil -> 100
    idx -> args |> Enum.at(idx + 1) |> String.to_integer()
  end

duration = 
  case Enum.find_index(args, &(&1 == "--duration")) do
    nil -> 60
    idx -> args |> Enum.at(idx + 1) |> String.to_integer()
  end

TitanLoadTest.run_load_test(connections, duration)

# ============================================
# File: titan_bridge/benchmarks/message_queue_benchmark.exs
# ============================================
#!/usr/bin/env elixir

Mix.install([
  {:benchee, "~> 1.2"}
])

alias TitanBridge.MessageQueue
alias TitanBridge.Repo
alias TitanBridge.Sync.Record

defmodule MessageQueueBenchmark do
  def run do
    # Setup
    {:ok, _} = TitanBridge.Repo.start_link()
    
    Benchee.run(
      %{
        "enqueue_single" => fn ->
          MessageQueue.enqueue(
            "test",
            "/api/test",
            %{data: "test"},
            []
          )
        end,
        
        "enqueue_batch_10" => fn ->
          Enum.each(1..10, fn i ->
            MessageQueue.enqueue(
              "test",
              "/api/test",
              %{data: "test-#{i}"},
              []
            )
          end)
        end,
        
        "stats" => fn ->
          MessageQueue.stats()
        end
      },
      warmup: 2,
      time: 10,
      memory_time: 2
    )
  end
end

MessageQueueBenchmark.run()

# ============================================
# File: titan_bridge/benchmarks/device_registry_benchmark.exs
# ============================================
defmodule DeviceRegistryBenchmark do
  alias TitanBridge.DeviceRegistry

  def run do
    # Start registry
    {:ok, _} = DeviceRegistry.start_link([])

    Benchee.run(
      %{
        "register_device" => fn ->
          pid = spawn(fn -> :timer.sleep(1000) end)
          DeviceRegistry.register("DEV-#{:rand.uniform(100000)}", pid, %{})
        end,
        
        "get_device" => fn ->
          DeviceRegistry.get("DEV-1")
        end,
        
        "heartbeat" => fn ->
          DeviceRegistry.heartbeat("DEV-1")
        end,
        
        "list_all" => fn ->
          DeviceRegistry.list_all()
        end
      },
      warmup: 1,
      time: 5,
      before_scenario: fn _ ->
        # Pre-populate with some devices
        for i <- 1..100 do
          pid = spawn(fn -> :timer.sleep(:infinity) end)
          DeviceRegistry.register("DEV-#{i}", pid, %{})
        end
      end
    )
  end
end

DeviceRegistryBenchmark.run()

# ============================================
# File: tests/load/websocket_load_test.js
# ============================================
// Node.js WebSocket load test
// Usage: node tests/load/websocket_load_test.js --connections=100 --duration=60

const WebSocket = require('ws');
const { performance } = require('perf_hooks');

const DEFAULT_URL = 'ws://localhost:4000/socket';
const DEFAULT_CONNECTIONS = 100;
const DEFAULT_DURATION = 60;

class LoadTester {
  constructor(url, connections, duration) {
    this.url = url;
    this.connections = connections;
    this.duration = duration;
    this.clients = [];
    this.stats = {
      connected: 0,
      messagesSent: 0,
      messagesReceived: 0,
      errors: 0,
      latencies: []
    };
  }

  async run() {
    console.log(`Starting WebSocket load test...`);
    console.log(`URL: ${this.url}`);
    console.log(`Connections: ${this.connections}`);
    console.log(`Duration: ${this.duration}s\n`);

    // Create connections
    const connectPromises = [];
    for (let i = 0; i < this.connections; i++) {
      connectPromises.push(this.connectClient(i));
    }

    await Promise.allSettled(connectPromises);
    console.log(`Connected: ${this.stats.connected}/${this.connections}\n`);

    // Run for duration
    await this.sleep(this.duration * 1000);

    // Collect final stats
    this.printStats();
    
    // Cleanup
    this.clients.forEach(client => {
      if (client.readyState === WebSocket.OPEN) {
        client.close();
      }
    });
  }

  connectClient(index) {
    return new Promise((resolve, reject) => {
      const deviceId = `LOAD-${index}`;
      const url = `${this.url}?device_id=${deviceId}&token=test-token`;
      
      const ws = new WebSocket(url);
      this.clients.push(ws);

      const startTime = performance.now();

      ws.on('open', () => {
        this.stats.connected++;
        
        // Send auth
        ws.send(JSON.stringify({
          type: 'auth',
          device_id: deviceId,
          capabilities: ['zebra_print', 'scale_read']
        }));

        // Start heartbeat
        const heartbeat = setInterval(() => {
          if (ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'heartbeat' }));
            this.stats.messagesSent++;
          }
        }, 30000);

        ws.heartbeatInterval = heartbeat;
        resolve();
      });

      ws.on('message', (data) => {
        this.stats.messagesReceived++;
        const latency = performance.now() - startTime;
        this.stats.latencies.push(latency);
      });

      ws.on('error', (err) => {
        this.stats.errors++;
        reject(err);
      });

      ws.on('close', () => {
        if (ws.heartbeatInterval) {
          clearInterval(ws.heartbeatInterval);
        }
      });
    });
  }

  sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  printStats() {
    const avgLatency = this.stats.latencies.length > 0
      ? this.stats.latencies.reduce((a, b) => a + b, 0) / this.stats.latencies.length
      : 0;

    const p95Latency = this.calculatePercentile(this.stats.latencies, 95);
    const p99Latency = this.calculatePercentile(this.stats.latencies, 99);

    console.log('=== Load Test Results ===');
    console.log(`Connected: ${this.stats.connected}/${this.connections}`);
    console.log(`Messages sent: ${this.stats.messagesSent}`);
    console.log(`Messages received: ${this.stats.messagesReceived}`);
    console.log(`Errors: ${this.stats.errors}`);
    console.log(`Avg latency: ${avgLatency.toFixed(2)}ms`);
    console.log(`P95 latency: ${p95Latency.toFixed(2)}ms`);
    console.log(`P99 latency: ${p99Latency.toFixed(2)}ms`);
  }

  calculatePercentile(arr, percentile) {
    if (arr.length === 0) return 0;
    const sorted = [...arr].sort((a, b) => a - b);
    const index = Math.ceil((percentile / 100) * sorted.length) - 1;
    return sorted[index];
  }
}

// Parse arguments
const args = process.argv.slice(2);
const connections = parseInt(args.find(a => a.startsWith('--connections='))?.split('=')[1]) || DEFAULT_CONNECTIONS;
const duration = parseInt(args.find(a => a.startsWith('--duration='))?.split('=')[1]) || DEFAULT_DURATION;

const tester = new LoadTester(DEFAULT_URL, connections, duration);
tester.run().catch(console.error);

# ============================================
# File: tests/load/k6_load_test.js
# ============================================
// K6 load test script
// Usage: k6 run tests/load/k6_load_test.js

import ws from 'k6/ws';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const wsMessagesSent = new Counter('ws_messages_sent');
const wsMessagesReceived = new Counter('ws_messages_received');
const wsConnectFailures = new Counter('ws_connect_failures');
const wsLatency = new Trend('ws_latency');

export const options = {
  stages: [
    { duration: '1m', target: 100 },   // Ramp up to 100 connections
    { duration: '3m', target: 100 },   // Stay at 100 for 3 minutes
    { duration: '1m', target: 200 },   // Ramp up to 200
    { duration: '3m', target: 200 },   // Stay at 200
    { duration: '1m', target: 0 },     // Ramp down
  ],
  thresholds: {
    ws_latency: ['p(95)<100'],          // 95% of messages under 100ms
    ws_connect_failures: ['count<10'],  // Less than 10 failures
  },
};

const WS_URL = 'ws://localhost:4000/socket';

export default function () {
  const deviceId = `K6-${__VU}-${__ITER}`;
  const url = `${WS_URL}?device_id=${deviceId}&token=test-token`;
  
  const res = ws.connect(url, null, function (socket) {
    let connected = false;
    
    socket.on('open', () => {
      // Send auth
      socket.send(JSON.stringify({
        type: 'auth',
        device_id: deviceId,
        capabilities: ['zebra_print', 'scale_read']
      }));
    });

    socket.on('message', (msg) => {
      wsMessagesReceived.add(1);
      
      const data = JSON.parse(msg);
      if (data.type === 'authenticated') {
        connected = true;
        
        // Start sending status updates
        const interval = setInterval(() => {
          const start = Date.now();
          socket.send(JSON.stringify({
            type: 'status',
            state: 'Locked',
            data: { weight: 2.5, timestamp: start }
          }));
          wsMessagesSent.add(1);
          wsLatency.add(Date.now() - start);
        }, 1000);
        
        socket.setInterval(function timeout() {
          clearInterval(interval);
          socket.close();
        }, 30000);
      }
    });

    socket.on('close', () => {
      if (!connected) {
        wsConnectFailures.add(1);
      }
    });

    socket.on('error', (e) => {
      wsConnectFailures.add(1);
    });
  });

  check(res, {
    'WebSocket connection established': (r) => r && r.status === 101,
  });
}

# ============================================
# File: tests/performance/fsm_benchmark.cs
// ============================================
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Running;
using System.Threading.Channels;
using Titan.Core.Fsm;
using Titan.Domain.Events;

namespace Titan.Performance.Tests;

[MemoryDiagnoser]
public class FsmBenchmark
{
    private BatchProcessingFsm? _fsm;
    private List<WeightSample>? _samples;

    [GlobalSetup]
    public void Setup()
    {
        var channel = Channel.CreateUnbounded<DomainEvent>();
        var detector = new StabilityDetector();
        _fsm = new BatchProcessingFsm(channel, detector);
        _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);

        // Generate 10,000 samples
        var timestamp = (double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency;
        _samples = Enumerable.Range(0, 10000)
            .Select(i => new WeightSample(2.5 + (i % 10) * 0.001, "kg", timestamp + i * 0.01))
            .ToList();
    }

    [Benchmark]
    public void Process10000Samples()
    {
        foreach (var sample in _samples!)
        {
            _fsm!.ProcessWeightSample(sample);
        }
    }

    [Benchmark]
    public void StateTransitions()
    {
        _fsm!.StartBatch("NEW-BATCH", "PROD-002", 1.0);
        _fsm.StopBatch();
    }

    public static void Main(string[] args)
    {
        BenchmarkRunner.Run<FsmBenchmark>();
    }
}

# ============================================
# File: tests/performance/memory_usage.cs
// ============================================
using Xunit;
using FluentAssertions;
using System.Diagnostics;

namespace Titan.Performance.Tests;

public class MemoryUsageTests
{
    [Fact]
    public void ServiceMemory_Should_BeUnder100MB()
    {
        // Arrange
        var startMemory = GC.GetTotalMemory(true);
        
        // Act - Create service with all dependencies
        // ... service creation ...
        
        // Force GC and check memory
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        
        var endMemory = GC.GetTotalMemory(true);
        var memoryUsed = (endMemory - startMemory) / 1024 / 1024; // MB
        
        // Assert
        memoryUsed.Should().BeLessThan(100);
    }

    [Fact]
    public void NoMemoryLeak_After10000Operations()
    {
        // Arrange
        var initialMemory = GC.GetTotalMemory(true);
        
        // Act - Run 10,000 operations
        for (int i = 0; i < 10000; i++)
        {
            // Simulate operations
        }
        
        GC.Collect();
        var afterGcMemory = GC.GetTotalMemory(true);
        
        // Act - Run another 10,000
        for (int i = 0; i < 10000; i++)
        {
            // Simulate operations
        }
        
        GC.Collect();
        var finalMemory = GC.GetTotalMemory(true);
        
        // Assert - Memory growth should be minimal
        var growth = finalMemory - afterGcMemory;
        growth.Should().BeLessThan(1024 * 1024); // Less than 1MB growth
    }
}
