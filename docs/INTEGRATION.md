# TITAN 系统集成指南

## 完整架构概览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ERPNext (Python)                               │
│                     单一事实来源 (Single Source of Truth)                 │
│                          "Daftar" - Passiv Baza                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │ HTTPS/REST API
                                    │
┌─────────────────────────────────────────────────────────────────────────┐
│                    TITAN BRIDGE (Elixir Phoenix)                        │
│                        "Tezkor Pochtalon"                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐ │
│  │ MessageQueue│  │DeviceRegistry│  │Telegram Bot │  │  ERP Sync      │ │
│  │  (ETS/DB)   │  │  (ETS)      │  │  (Memory)   │  │   Worker       │ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────────────┘ │
│                                                                          │
│  WebSocket Endpoint: ws://bridge:4000/socket                            │
│  REST API: http://bridge:4000/api                                       │
│  Telegram: @titan_core_bot                                              │
└─────────────────────────────────────────────────────────────────────────┘
                                    │ WebSocket (Bidirectional)
                                    │
┌─────────────────────────────────────────────────────────────────────────┐
│                    TITAN CORE (C# .NET 10)                              │
│                      "Haqiqiy Boshliq"                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐ │
│  │  FSM        │  │ BatchService│  │  Hardware   │  │   TUI          │ │
│  │ (StateMachine│  │ (Business)  │  │ (Scale/Print)│  │ (Terminal.Gui)│ │
│  └─────────────┘  └─────────────┘  └─────────────┘  └────────────────┘ │
│                                                                          │
│  PostgreSQL: Host=localhost;Database=titan                              │
│  In-Memory Cache: Microsoft.Extensions.Caching.Memory                   │
└─────────────────────────────────────────────────────────────────────────┘
```

## 1. C# Core → Elixir Bridge 连接

### 1.1 创建 WebSocket Client

在 `Titan.Infrastructure` 中添加:

```csharp
// File: src/Titan.Infrastructure/Messaging/ElixirBridgeClient.cs
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Titan.Infrastructure.Messaging;

public interface IElixirBridgeClient
{
    Task<bool> ConnectAsync(string deviceId, string token, CancellationToken ct = default);
    Task DisconnectAsync(CancellationToken ct = default);
    Task SendEventAsync(object payload, CancellationToken ct = default);
    Task SendStatusAsync(string state, object data, CancellationToken ct = default);
    event EventHandler<BridgeCommand>? OnCommandReceived;
}

public sealed class ElixirBridgeClient : IElixirBridgeClient, IDisposable
{
    private readonly ILogger<ElixirBridgeClient> _logger;
    private readonly string _bridgeUrl;
    private ClientWebSocket? _webSocket;
    private CancellationTokenSource? _cts;
    private Task? _receiveTask;
    
    public event EventHandler<BridgeCommand>? OnCommandReceived;
    
    public bool IsConnected => _webSocket?.State == WebSocketState.Open;

    public ElixirBridgeClient(ILogger<ElixirBridgeClient> logger, string bridgeUrl)
    {
        _logger = logger;
        _bridgeUrl = bridgeUrl;
    }

    public async Task<bool> ConnectAsync(string deviceId, string token, CancellationToken ct = default)
    {
        try
        {
            _webSocket = new ClientWebSocket();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            
            var uri = new Uri($"{_bridgeUrl}?device_id={deviceId}&token={token}");
            await _webSocket.ConnectAsync(uri, _cts.Token);
            
            // Send auth message
            await SendAsync(new { type = "auth", device_id = deviceId, capabilities = new[] { "zebra_print", "scale_read", "rfid_encode" } });
            
            // Start receive loop
            _receiveTask = ReceiveLoopAsync(_cts.Token);
            
            // Start heartbeat
            _ = HeartbeatLoopAsync(_cts.Token);
            
            _logger.LogInformation("Connected to Elixir Bridge: {Url}", _bridgeUrl);
            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to connect to Elixir Bridge");
            return false;
        }
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        _cts?.Cancel();
        
        if (_webSocket?.State == WebSocketState.Open)
        {
            await _webSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "Disconnecting", ct);
        }
        
        _webSocket?.Dispose();
        _logger.LogInformation("Disconnected from Elixir Bridge");
    }

    public async Task SendEventAsync(object payload, CancellationToken ct = default)
    {
        if (!IsConnected) return;
        
        var message = new { type = "event", payload };
        await SendAsync(message, ct);
    }

    public async Task SendStatusAsync(string state, object data, CancellationToken ct = default)
    {
        if (!IsConnected) return;
        
        var message = new { type = "status", state, data };
        await SendAsync(message, ct);
    }

    private async Task SendAsync(object message, CancellationToken ct = default)
    {
        if (_webSocket?.State != WebSocketState.Open) return;
        
        var json = JsonSerializer.Serialize(message);
        var bytes = Encoding.UTF8.GetBytes(json);
        await _webSocket.SendAsync(
            new ArraySegment<byte>(bytes),
            WebSocketMessageType.Text,
            true,
            ct);
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        var buffer = new byte[4096];
        
        while (!ct.IsCancellationRequested && _webSocket?.State == WebSocketState.Open)
        {
            try
            {
                var result = await _webSocket.ReceiveAsync(
                    new ArraySegment<byte>(buffer), ct);
                
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    await _webSocket.CloseAsync(
                        WebSocketCloseStatus.NormalClosure, 
                        "Closing", 
                        CancellationToken.None);
                    break;
                }
                
                var json = Encoding.UTF8.GetString(buffer, 0, result.Count);
                var command = JsonSerializer.Deserialize<BridgeCommand>(json);
                
                if (command != null)
                {
                    OnCommandReceived?.Invoke(this, command);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error receiving message");
            }
        }
    }

    private async Task HeartbeatLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && IsConnected)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(30), ct);
                await SendAsync(new { type = "heartbeat" }, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    public void Dispose()
    {
        DisconnectAsync().Wait();
        _webSocket?.Dispose();
        _cts?.Dispose();
    }
}

public class BridgeCommand
{
    public string Type { get; set; } = "";
    public string Action { get; set; } = "";
    public Dictionary<string, object>? Params { get; set; }
}
```

### 1.2 集成到 BatchProcessingService

```csharp
// File: src/Titan.Core/Services/BatchProcessingService.cs (Updated)
public sealed class BatchProcessingService : IDisposable
{
    private readonly IElixirBridgeClient _bridgeClient;
    
    public BatchProcessingService(
        IWeightRecordRepository weightRepository,
        IProductRepository productRepository,
        ICacheService cache,
        IEpcGenerator epcGenerator,
        IElixirBridgeClient bridgeClient,  // Add this
        ILogger<BatchProcessingService> logger)
    {
        // ... existing code ...
        _bridgeClient = bridgeClient;
        
        // Subscribe to commands from bridge
        _bridgeClient.OnCommandReceived += OnBridgeCommand;
    }

    private void OnBridgeCommand(object? sender, BridgeCommand command)
    {
        _logger.LogInformation("Received command from bridge: {Action}", command.Action);
        
        switch (command.Action)
        {
            case "start_batch":
                var batchId = command.Params?["batch_id"]?.ToString();
                var productId = command.Params?["product_id"]?.ToString();
                if (batchId != null && productId != null)
                {
                    StartBatch(batchId, productId);
                }
                break;
                
            case "stop_batch":
                StopBatch();
                break;
                
            case "change_product":
                var newProductId = command.Params?["product_id"]?.ToString();
                if (newProductId != null)
                {
                    ChangeProduct(newProductId);
                }
                break;
        }
    }

    private async Task HandleLabelPrintedAsync(LabelPrintedEvent evt)
    {
        // ... existing code ...
        
        // Send to Elixir Bridge for ERP sync
        await _bridgeClient.SendEventAsync(new
        {
            type = "weight_record",
            data = new
            {
                evt.BatchId,
                evt.ProductId,
                evt.Weight,
                evt.EpcCode,
                Timestamp = DateTime.UtcNow
            }
        });
        
        _logger.LogInformation("Weight record sent to bridge: {Epc}", evt.EpcCode);
    }
    
    // Update FSM to send status changes
    private void TransitionTo(BatchProcessingState newState, double? timestamp = null)
    {
        State = newState;
        _stateEnteredAt = timestamp ?? GetTimestamp();
        
        // Send status update to bridge
        _ = _bridgeClient.SendStatusAsync(
            newState.ToString(),
            new { weight = LockedWeight, product = ActiveProductId });
    }
}
```

## 2. Elixir Bridge → C# Core 消息格式

### 2.1 C# Core 发送的消息

```json
// 1. 认证
{
  "type": "auth",
  "device_id": "DEV-001",
  "capabilities": ["zebra_print", "scale_read", "rfid_encode"]
}

// 2. 心跳
{
  "type": "heartbeat"
}

// 3. 状态更新
{
  "type": "status",
  "state": "Locked",
  "data": {
    "weight": 1.234,
    "product_id": "PROD-001",
    "batch_id": "BATCH-001"
  }
}

// 4. 事件 - 重量记录
{
  "type": "event",
  "payload": {
    "type": "weight_record",
    "data": {
      "batch_id": "BATCH-001",
      "product_id": "PROD-001",
      "weight": 1.234,
      "epc_code": "3034257BF7194E4000000001",
      "timestamp": "2024-01-15T10:30:00Z"
    }
  }
}

// 5. 事件 - RFID 读取
{
  "type": "event",
  "payload": {
    "type": "tag_read",
    "data": {
      "epc": "3034257BF7194E4000000001",
      "rssi": -65,
      "antenna": 1
    }
  }
}
```

### 2.2 Elixir Bridge 发送的命令

```json
// 1. 开始批次
{
  "type": "command",
  "action": "start_batch",
  "params": {
    "batch_id": "BATCH-2024-001",
    "product_id": "PROD-001",
    "placement_min_weight": 1.0
  }
}

// 2. 停止批次
{
  "type": "command",
  "action": "stop_batch"
}

// 3. 切换产品
{
  "type": "command",
  "action": "change_product",
  "params": {
    "product_id": "PROD-002"
  }
}
```

## 3. 配置集成

### 3.1 C# appsettings.json

```json
{
  "ConnectionStrings": {
    "PostgreSQL": "Host=localhost;Database=titan;Username=titan;Password=titan"
  },
  "Hardware": {
    "ScalePort": "/dev/ttyUSB0",
    "PrinterDevice": "/dev/usb/lp0"
  },
  "ElixirBridge": {
    "Url": "ws://localhost:4000/socket",
    "DeviceId": "DEV-001",
    "ApiToken": "your-device-token-from-erp"
  },
  "Telegram": {
    "Enabled": true,
    "BotUsername": "@titan_core_bot"
  }
}
```

### 3.2 Elixir .env

```bash
# Database
DATABASE_URL=ecto://titan:titan_secret@localhost/titan_bridge_dev

# Phoenix
PORT=4000
SECRET_KEY_BASE=your-secret-key-base
SESSION_ENCRYPTION_KEY=your-32-byte-key

# Telegram
TELEGRAM_BOT_TOKEN=your-bot-token
TELEGRAM_BOT_USERNAME=titan_core_bot

# ERP
ERP_URL=https://erp.accord.uz
ERP_API_KEY=your-erp-api-key
ERP_API_SECRET=your-erp-api-secret
```

## 4. 部署拓扑

### 4.1 单节点部署

```
┌─────────────────────────────────────────┐
│              Linux Server               │
│  ┌─────────────────────────────────┐   │
│  │  Docker Compose                 │   │
│  │  ┌──────────┐  ┌──────────────┐│   │
│  │  │PostgreSQL│  │Titan Bridge  ││   │
│  │  │  :5432   │  │  Elixir      ││   │
│  │  └──────────┘  │  :4000       ││   │
│  │                └──────────────┘│   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │  Titan Core (C# .NET 10)        │   │
│  │  - FSM                          │   │
│  │  - Hardware Control             │   │
│  │  - TUI                          │   │
│  └─────────────────────────────────┘   │
│       │        │                        │
│    USB │     USB                        │
│       ▼        ▼                        │
│   ┌──────┐  ┌────────┐                 │
│   │ Scale│  │ Printer│                 │
│   └──────┘  └────────┘                 │
└─────────────────────────────────────────┘
```

### 4.2 Docker Compose 完整配置

```yaml
# File: docker-compose.full.yml
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: titan
      POSTGRES_PASSWORD: titan_secret
      POSTGRES_DB: titan_prod
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - titan-network

  titan-bridge:
    build:
      context: ./titan_bridge
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: ecto://titan:titan_secret@postgres/titan_prod
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      SESSION_ENCRYPTION_KEY: ${SESSION_ENCRYPTION_KEY}
      TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN}
      ERP_URL: ${ERP_URL}
    ports:
      - "4000:4000"
    depends_on:
      - postgres
    networks:
      - titan-network

  titan-core:
    build:
      context: ./titan_core
      dockerfile: Dockerfile
    privileged: true
    devices:
      - "/dev/ttyUSB0:/dev/ttyUSB0"
      - "/dev/usb/lp0:/dev/usb/lp0"
    environment:
      ConnectionStrings__PostgreSQL: "Host=postgres;Database=titan_prod;Username=titan;Password=titan_secret"
      Hardware__ScalePort: "/dev/ttyUSB0"
      Hardware__PrinterDevice: "/dev/usb/lp0"
      ElixirBridge__Url: "ws://titan-bridge:4000/socket"
      ElixirBridge__DeviceId: "DEV-001"
      ElixirBridge__ApiToken: "${DEVICE_TOKEN}"
    depends_on:
      - postgres
      - titan-bridge
    networks:
      - titan-network
    stdin_open: true
    tty: true

volumes:
  postgres_data:

networks:
  titan-network:
    driver: bridge
```

## 5. 启动顺序

```bash
# 1. 启动数据库
docker-compose up -d postgres

# 2. 启动 Elixir Bridge
cd titan_bridge
docker-compose up -d titan-bridge

# 3. 运行数据库迁移
docker-compose exec titan-bridge bin/migrate

# 4. 启动 C# Core
cd titan_core
docker-compose up -d titan-core

# 5. 验证连接
curl http://localhost:4000/api/health
```

## 6. 故障排查

### 6.1 检查设备连接

```bash
# 在 C# Core 容器中检查硬件
ls -la /dev/ttyUSB* /dev/usb/lp*

# 检查 Elixir Bridge 日志
docker-compose logs -f titan-bridge

# 检查 C# Core 日志
docker-compose logs -f titan-core
```

### 6.2 测试 WebSocket 连接

```bash
# 使用 wscat
npm install -g wscat
wscat -c "ws://localhost:4000/socket?device_id=DEV-001&token=test"

> {"type": "auth", "device_id": "DEV-001", "capabilities": ["print"]}
> {"type": "heartbeat"}
```

### 6.3 测试 Telegram Bot

```bash
# 发送测试消息
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>" \
  -d "text=Test message"
```

## 7. 安全清单

- [ ] 更改所有默认密码
- [ ] 使用强密钥 (SECRET_KEY_BASE, SESSION_ENCRYPTION_KEY)
- [ ] 启用 PostgreSQL SSL
- [ ] 配置防火墙 (仅开放 4000 端口)
- [ ] Telegram Token 仅保存在内存
- [ ] 使用 Docker secrets 管理敏感信息
- [ ] 定期备份数据库
- [ ] 启用日志审计

## 8. 性能调优

### 8.1 PostgreSQL

```sql
-- 连接池优化
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET shared_buffers = '256MB';

-- 索引
CREATE INDEX CONCURRENTLY idx_events_device_time 
  ON events(device_id, created_at);
```

### 8.2 Elixir VM

```bash
# vm.args
+S 4          # Scheduler threads
+A 16         # Async threads
+P 500000     # Process limit
```

## 9. 监控端点

```bash
# 系统健康
curl http://localhost:4000/api/health

# 队列状态
curl http://localhost:4000/api/queue/stats

# 设备列表
curl http://localhost:4000/api/devices

# Prometheus 指标
curl http://localhost:4000/metrics
```
