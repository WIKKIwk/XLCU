# TITAN BRIDGE - Phase 2 Complete

## 项目概述

Titan Bridge 是基于 Elixir Phoenix 的高性能中间件，作为 ERPNext 与 C# Core 之间的"Tezkor Pochtalon"（快速邮差）。同时包含完整的 Telegram Bot 控制模块。

## 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│  ERPNext (Python)                                           │
│  └─ 单一事实来源 (Single Source of Truth)                    │
└─────────────────────────────────────────────────────────────┘
                            ▲
                            │ HTTPS / REST API
                            │
┌─────────────────────────────────────────────────────────────┐
│  TITAN BRIDGE (Elixir Phoenix)                              │
│  ├─ Message Queue: 消息队列与重试机制                         │
│  ├─ Device Registry: 设备状态管理                            │
│  ├─ WebSocket: 与 C# Core 实时通信                          │
│  ├─ Telegram Bot: 无头设备控制                              │
│  └─ ERP Sync Worker: ERPNext 数据同步                       │
└─────────────────────────────────────────────────────────────┘
                            │ WebSocket
                            │
┌─────────────────────────────────────────────────────────────┐
│  TITAN CORE (C# .NET 10)                                    │
│  └─ FSM, Hardware, TUI                                      │
└─────────────────────────────────────────────────────────────┘
```

## 核心功能

### 1. WebSocket 通信 (C# ↔ Elixir)

```elixir
# C# Core 连接
WebSocket connect -> auth(device_id, token) -> heartbeat -> events

# 消息类型
- auth: 认证
- heartbeat: 心跳检测
- event: 设备事件 (weight, print, tag)
- status: 状态更新
- command: 服务器命令
```

### 2. 消息队列 (Message Queue)

- **优先级队列**: 高优先级消息优先处理
- **自动重试**: 指数退避策略 (1s, 2s, 4s, 8s...)
- **死信队列**: 5次失败后进入死信队列
- **批量处理**: 每批最多100条记录

### 3. Telegram Bot

#### 安全协议 (CRITICAL)

1. **用户发送 `/start`**
2. **输入 ERP URL** (e.g., `erp.accord.uz`)
3. **输入 API Token**
   - Token 立即加密
   - **原始消息被删除**
   - 仅存储在内存 (ETS)
4. **会话 24小时后过期**

#### 命令列表

| 命令 | 说明 |
|------|------|
| `/start` | 初始化 Bot |
| `/status` | 查看设备状态 |
| `/batch start` | 开始批次 |
| `/batch stop` | 停止批次 |
| `/product` | 选择产品 (Inline 菜单) |
| `/settings` | 查看设置 |
| `/logout` | 清除会话 |

#### Inline 菜单示例

```
📦 Select product:
┌─────────────────────────┐
│ Product A (CODE-001)    │
│ Product B (CODE-002)    │
│ Product C (CODE-003)    │
├─────────────────────────┤
│ 🔄 Refresh              │
└─────────────────────────┘
```

### 4. 设备注册表 (Device Registry)

```elixir
%DeviceState{
  device_id: "DEV-xxx",
  status: :online | :offline | :busy | :error,
  socket_pid: pid(),
  connected_at: DateTime,
  last_heartbeat: DateTime,
  metadata: %{state: "Locked", weight: 1.234}
}
```

### 5. ERP 同步

```elixir
# 同步 Stock Entry
type: "stock_entry"
endpoint: "/api/resource/Stock Entry"
payload: %{item_code, qty, warehouse, epc}

# 同步 Tag Data
type: "tag_data"  
endpoint: "/api/method/rfidenter.edge_event_report"
payload: %{batch_id, tags}
```

## 文件结构

```
titan_bridge/
├── config/
│   ├── config.exs          # 主配置
│   ├── dev.exs             # 开发环境
│   ├── prod.exs            # 生产环境
│   ├── runtime.exs         # 运行时配置
│   └── test.exs            # 测试环境
├── lib/
│   ├── titan_bridge/
│   │   ├── application.ex      # OTP Application
│   │   ├── repo.ex             # Ecto Repo
│   │   ├── schema.ex           # Base Schema
│   │   ├── devices/
│   │   │   └── device.ex       # Device Schema
│   │   ├── events/
│   │   │   └── event.ex        # Event Schema
│   │   ├── sync/
│   │   │   └── record.ex       # Sync Record Schema
│   │   ├── message_queue.ex    # 消息队列
│   │   ├── device_registry.ex  # 设备注册表
│   │   ├── telegram/
│   │   │   ├── bot.ex          # Telegram Bot
│   │   │   ├── session.ex      # 会话管理 (内存加密)
│   │   │   └── notifier.ex     # 通知服务
│   │   ├── erp/
│   │   │   ├── client.ex       # ERP HTTP Client
│   │   │   └── sync_worker.ex  # 同步 Worker
│   │   └── edge/
│   │       └── connection_manager.ex
│   └── titan_bridge_web/
│       ├── endpoint.ex
│       ├── router.ex
│       ├── channels/
│       │   ├── edge_socket.ex    # WebSocket 处理
│       │   └── device_channel.ex
│       └── controllers/
│           └── api_controller.ex
├── priv/
│   └── repo/migrations/      # 数据库迁移
├── Dockerfile
├── docker-compose.yml
├── docker-compose.dev.yml
└── run.sh                    # 构建脚本
```

## 环境变量

```bash
# Database
export DATABASE_URL=ecto://titan:titan_secret@postgres/titan_bridge_prod

# Phoenix
export PORT=4000
export PHX_HOST=localhost
export SECRET_KEY_BASE=your-secret-key-base

# Security (32字节随机密钥)
export SESSION_ENCRYPTION_KEY=your-32-byte-encryption-key
export TITAN_API_TOKEN=your-api-token

# Telegram (@BotFather)
export TELEGRAM_BOT_TOKEN=1234567890:ABCdef...
export TELEGRAM_BOT_USERNAME=titan_core_bot

# ERPNext
export ERP_URL=https://erp.accord.uz
export ERP_API_KEY=your-api-key
export ERP_API_SECRET=your-api-secret
```

## 部署

### 开发环境

```bash
# 1. 克隆项目
cd titan_bridge

# 2. 复制环境变量
cp .env.example .env
# 编辑 .env 填入你的配置

# 3. 启动 Docker 依赖
docker-compose -f docker-compose.dev.yml up -d

# 4. 安装依赖
mix deps.get

# 5. 数据库设置
mix ecto.setup

# 6. 运行
mix phx.server

# 访问: http://localhost:4000
# WebSocket: ws://localhost:4000/socket
```

### 生产环境

```bash
# 1. 生成密钥
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export SESSION_ENCRYPTION_KEY=$(openssl rand -base64 32)

# 2. 构建 Docker 镜像
docker-compose up --build -d

# 3. 运行迁移
docker-compose exec titan-bridge bin/migrate
```

## API 端点

### REST API

```
GET  /api/health           # 健康检查
GET  /api/devices         # 设备列表
GET  /api/devices/:id     # 设备详情
POST /api/devices/:id/command  # 发送命令
GET  /api/queue/stats     # 队列统计
```

### WebSocket

```javascript
// 连接
const socket = new WebSocket('ws://localhost:4000/socket?device_id=DEV-001&token=xxx');

// 认证
socket.send(JSON.stringify({
  type: 'auth',
  device_id: 'DEV-001',
  capabilities: ['zebra_print', 'scale_read']
}));

// 心跳
socket.send(JSON.stringify({type: 'heartbeat'}));

// 发送事件
socket.send(JSON.stringify({
  type: 'event',
  payload: {type: 'weight_record', data: {...}}
}));
```

## C# Core 集成

在 `Titan.Core` 中创建 Elixir Bridge Client:

```csharp
// 服务注册
services.AddSingleton<IElixirBridgeClient, ElixirBridgeClient>();

// 配置
builder.Configuration.AddEnvironmentVariables(prefix: "TITAN_");

// appsettings.json
{
  "Elixir": {
    "Url": "ws://localhost:4000/socket",
    "DeviceId": "DEV-001",
    "ApiToken": "your-token"
  }
}
```

## 性能指标

| 指标 | 目标 | 说明 |
|------|------|------|
| WebSocket 延迟 | < 10ms | 本地网络 |
| 消息队列吞吐 | 10,000 msg/s | 批量处理 |
| 设备连接数 | 100,000+ | 水平扩展 |
| 会话内存 | < 1KB | 每用户 |
| 重启恢复 | < 5s | 从数据库恢复 |

## 下一步 (Phase 3)

1. **测试套件**
   - 单元测试 (ExUnit)
   - 集成测试
   - WebSocket 压力测试

2. **监控**
   - Prometheus 指标
   - Grafana 仪表盘
   - 告警规则

3. **安全加固**
   - TLS 证书
   - API 速率限制
   - IP 白名单

## 文件列表

- `PROJECT_TITAN_ELIXIR.exs` - 项目配置, Schema, Session
- `PROJECT_TITAN_ELIXIR2.exs` - MessageQueue, DeviceRegistry, ERP Client
- `PROJECT_TITAN_ELIXIR3.exs` - WebSocket, Channels, Router
- `PROJECT_TITAN_TELEGRAM.exs` - Telegram Bot, Notifier
- `PROJECT_TITAN_ELIXIR_CONFIG.exs` - 配置文件, 数据库迁移
- `PROJECT_TITAN_ELIXIR_DOCKER.exs` - Docker 配置, 部署脚本

## 许可

MIT License - Accord Organization
