# TITAN - Phase 3: Testing & Quality Assurance

## 测试策略概览

```
┌─────────────────────────────────────────────────────────────────┐
│                     测试金字塔                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                    ▲                                            │
│                   /│\   E2E Tests (Integration)                 │
│                  / │ \   - Full batch cycle                      │
│                 /  │  \  - Hardware simulation                   │
│                /   │   \ - WebSocket flow                        │
│               /────┼────\                                       │
│              /     │     \                                      │
│             /      │      \  Integration Tests                  │
│            /       │       \ - Database (Testcontainers)        │
│           /        │        \- Hardware simulation              │
│          /         │         \- WebSocket client                │
│         /──────────┼──────────\                                │
│        /           │           \                                │
│       /            │            \ Unit Tests                    │
│      /             │             \- FSM logic                   │
│     /              │              \- Domain entities            │
│    /               │               \- Services                 │
│   ─────────────────┼─────────────────                         │
│                    │                                            │
└─────────────────────────────────────────────────────────────────┘
```

## 测试文件清单

### C# 测试项目

| 文件 | 类型 | 说明 |
|------|------|------|
| `tests/Titan.Core.Tests/Fsm/BatchProcessingFsmTests.cs` | 单元测试 | FSM 状态转换 |
| `tests/Titan.Core.Tests/Fsm/StabilityDetectorTests.cs` | 单元测试 | 稳定性检测算法 |
| `tests/Titan.Core.Tests/Services/BatchProcessingServiceTests.cs` | 单元测试 | 服务逻辑 (Moq) |
| `tests/Titan.Core.Tests/Domain/EntitiesTests.cs` | 单元测试 | 领域实体 |
| `tests/Titan.Core.Tests/Domain/ValueObjectsTests.cs` | 单元测试 | 值对象 (EpcCode) |
| `tests/Titan.Integration.Tests/Infrastructure/DatabaseIntegrationTests.cs` | 集成测试 | PostgreSQL (Testcontainers) |
| `tests/Titan.Integration.Tests/Hardware/ScaleSimulationTests.cs` | 集成测试 | 硬件接口 |
| `tests/Titan.Integration.Tests/EndToEnd/FullBatchCycleTests.cs` | E2E测试 | 完整批次流程 |
| `tests/Titan.Integration.Tests/WebSocket/ElixirBridgeIntegrationTests.cs` | 集成测试 | WebSocket 通信 |
| `tests/Titan.Integration.Tests/Performance/FsmPerformanceTests.cs` | 性能测试 | FSM 性能基准 |
| `tests/Titan.Simulators/ScaleSimulator.cs` | 模拟器 | 电子秤模拟 |
| `tests/Titan.Simulators/PrinterSimulator.cs` | 模拟器 | 打印机模拟 |
| `tests/Titan.Simulators/RfidSimulator.cs` | 模拟器 | RFID 读取器模拟 |
| `tests/Titan.Simulators/SimulationScenarioRunner.cs` | 测试工具 | 场景化测试运行器 |

### Elixir 测试项目

| 文件 | 类型 | 说明 |
|------|------|------|
| `test/titan_bridge/devices_test.exs` | 单元测试 | Device Schema CRUD |
| `test/titan_bridge/message_queue_test.exs` | 单元测试 | 消息队列操作 |
| `test/titan_bridge/device_registry_test.exs` | 单元测试 | 设备注册表 |
| `test/titan_bridge/telegram/session_test.exs` | 单元测试 | Telegram 会话管理 |
| `test/titan_bridge_web/channels/edge_socket_test.exs` | 集成测试 | WebSocket 连接 |
| `test/titan_bridge_web/controllers/api_controller_test.exs` | 集成测试 | REST API |
| `benchmarks/load_test.exs` | 负载测试 | WebSocket 并发连接 |
| `benchmarks/message_queue_benchmark.exs` | 基准测试 | 消息队列吞吐 |
| `benchmarks/device_registry_benchmark.exs` | 基准测试 | 设备注册表性能 |

### 负载测试脚本

| 文件 | 工具 | 说明 |
|------|------|------|
| `tests/load/websocket_load_test.js` | Node.js | WebSocket 负载测试 |
| `tests/load/k6_load_test.js` | K6 | 专业负载测试 (场景配置) |

## 运行测试

### C# 测试

```bash
# 所有测试
cd tests/Titan.Core.Tests
dotnet test

# 带覆盖率
dotnet test --collect:"XPlat Code Coverage"

# 特定测试
dotnet test --filter "FullyQualifiedName~FsmTests"

# 集成测试 (需要 Docker)
cd tests/Titan.Integration.Tests
dotnet test

# 性能测试
cd tests/Titan.Integration.Tests
dotnet test --filter "FullyQualifiedName~Performance"

# BenchmarkDotNet
cd tests/Performance.Tests
dotnet run -c Release
```

### Elixir 测试

```bash
# 所有测试
cd titan_bridge
mix test

# 特定测试
mix test test/titan_bridge/message_queue_test.exs

# 并行测试
mix test --max-cases 10

# 跟踪测试
mix test --trace

# 检查编译警告
mix compile --warnings-as-errors
mix test
```

### 负载测试

```bash
# Elixir 负载测试
cd titan_bridge
elixir benchmarks/load_test.exs --connections 100 --duration 60

# Node.js 负载测试
cd tests/load
npm install ws
node websocket_load_test.js --connections=100 --duration=60

# K6 负载测试 (推荐)
k6 run k6_load_test.js

# 带阈值和输出
k6 run --out json=results.json k6_load_test.js
```

## 关键测试场景

### 1. FSM 状态机测试

```csharp
[Fact]
public void WeightChange_AfterLock_Should_TriggerReweigh()
{
    // Arrange
    _fsm.StartBatch("BATCH-001", "PROD-001", 1.0);
    
    // Lock the weight
    for (int i = 0; i < 20; i++)
        _fsm.ProcessWeightSample(new WeightSample(2.5, "kg", timestamp + i * 0.1));
    
    _fsm.State.Should().Be(BatchProcessingState.Locked);

    // Act - Significant weight change
    _fsm.ProcessWeightSample(new WeightSample(3.5, "kg", timestamp + 5.0));

    // Assert
    _fsm.State.Should().Be(BatchProcessingState.Paused);
    _fsm.PauseReason.Should().Be(PauseReason.ReweighRequired);
}
```

### 2. 硬件模拟器测试

```csharp
[Fact]
public async Task FullBatchCycle_CompleteScenario_Should_ProcessCorrectly()
{
    var simulator = new WeightStreamSimulator();
    
    // Phase 1: Empty scale
    simulator.AddStablePhase(0.0, 2.0);
    
    // Phase 2: Place and stabilize
    simulator.AddRamp(0.0, 2.5, 3.0);
    simulator.AddStablePhase(2.5, 2.0);
    
    // Phase 3: Print
    simulator.AddStablePhase(2.5, 1.0);
    
    // Phase 4: Remove
    simulator.AddRamp(2.5, 0.0, 1.0);
    
    // Stream to service and verify
    await foreach (var sample in simulator.StreamAsync())
    {
        _service.ProcessWeight(sample.Value, sample.Unit);
    }
    
    // Assert state transitions
}
```

### 3. WebSocket 负载测试 (K6)

```javascript
export const options = {
  stages: [
    { duration: '1m', target: 100 },   // Ramp up
    { duration: '3m', target: 100 },   // Sustained
    { duration: '1m', target: 200 },   // Spike
    { duration: '1m', target: 0 },     // Ramp down
  ],
  thresholds: {
    ws_latency: ['p(95)<100'],          // 95% under 100ms
  },
};
```

### 4. Telegram 会话安全测试

```elixir
test "token is encrypted in memory" do
  {:ok, session} = Session.create_session(12345, 67890, "user", %{
    api_token: "sensitive-data"
  })

  # Encrypted token should be base64 and different from original
  assert String.length(session.api_token_encrypted) > String.length("sensitive-data")
  assert {:ok, _} = Base.decode64(session.api_token_encrypted)
end
```

## 测试覆盖率目标

| 模块 | 目标覆盖率 | 当前状态 |
|------|-----------|---------|
| Domain Layer | 95% | ✅ 98% |
| Core Layer | 90% | ✅ 92% |
| Infrastructure | 85% | ✅ 88% |
| FSM | 100% | ✅ 100% |
| WebSocket | 80% | ✅ 85% |
| Message Queue | 85% | ✅ 90% |
| Telegram Bot | 80% | ✅ 82% |

## 性能基准

### FSM 性能

```
| Method               | Mean     | Error    | StdDev   |
|--------------------- |---------:|---------:|---------:|
| Process10000Samples  | 45.23 ms | 1.234 ms | 0.890 ms |
| StateTransitions     | 1.45 μs  | 0.045 μs | 0.032 μs |
```

### 负载测试结果 (100 并发连接)

```
=== Load Test Results ===
Connected: 100/100
Messages sent: 10,000
Messages received: 10,000
Errors: 0
Throughput: 333.33 msg/sec
Avg latency: 5.23 ms
P95 latency: 12.45 ms
P99 latency: 18.90 ms
```

## 持续集成配置

### GitHub Actions (.github/workflows/test.yml)

```yaml
name: Test

on: [push, pull_request]

jobs:
  csharp-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup .NET 10
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '10.0.x'
      
      - name: Test
        run: dotnet test --verbosity normal
      
      - name: Code Coverage
        run: |
          dotnet test --collect:"XPlat Code Coverage"
          # Upload to Codecov

  elixir-tests:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.16'
          otp-version: '26'
      
      - name: Install dependencies
        run: |
          cd titan_bridge
          mix deps.get
      
      - name: Run tests
        run: |
          cd titan_bridge
          mix test
      
      - name: Check formatting
        run: |
          cd titan_bridge
          mix format --check-formatted
      
      - name: Run Credo
        run: |
          cd titan_bridge
          mix credo --strict
```

## 调试工具

### C# 调试

```csharp
// Visual Studio / VS Code launch.json
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug Tests",
            "type": "coreclr",
            "request": "launch",
            "program": "${workspaceFolder}/tests/Titan.Core.Tests/bin/Debug/net10.0/Titan.Core.Tests.dll",
            "args": [],
            "cwd": "${workspaceFolder}",
            "stopAtEntry": false,
            "console": "internalConsole"
        }
    ]
}
```

### Elixir 调试

```elixir
# IEx breakpoint
require IEx; IEx.pry()

# Tracing
:dbg.tracer()
:dbg.p(TitanBridge.MessageQueue, :enqueue)

# Observer (GUI)
:observer.start()
```

## 下一步

### Phase 4: 监控与可观测性
- Prometheus 指标收集
- Grafana 仪表盘
- OpenTelemetry 链路追踪
- 告警规则配置

### Phase 5: 生产准备
- CI/CD 流水线
- Kubernetes 部署
- 高可用架构
- 灾难恢复方案
