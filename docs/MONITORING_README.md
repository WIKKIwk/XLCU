# TITAN - Phase 4: Monitoring & Observability

## 监控架构概览

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         MONITORING STACK                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌────────────┐  │
│  │  Prometheus │   │   Grafana   │   │    Loki     │   │  Jaeger    │  │
│  │  :9090      │   │   :3000     │   │   :3100     │   │  :16686    │  │
│  │             │   │             │   │             │   │            │  │
│  │ Metrics     │   │ Dashboards  │   │ Log Agg.    │   │ Tracing    │  │
│  │ Collection  │   │ Alerts      │   │ Storage     │   │ Analysis   │  │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └─────┬──────┘  │
│         │                 │                 │                │         │
│  ┌──────┴──────┐   ┌──────┴──────┐   ┌──────┴──────┐   ┌──────┴──────┐│
│  │ Alertmanager│   │ Promtail    │   │ Node Exp.   │   │  Postgres   ││
│  │  :9093      │   │  :9080      │   │  :9100      │   │  :9187      ││
│  │             │   │             │   │             │   │             ││
│  │ Alert       │   │ Log         │   │ System      │   │ Database    ││
│  │ Routing     │   │ Collection  │   │ Metrics     │   │ Metrics     ││
│  └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘│
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Scrapes
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           TITAN APPLICATIONS                            │
│                                                                         │
│  ┌─────────────────────────────────┐   ┌─────────────────────────────┐ │
│  │      TITAN CORE (C#)            │   │   TITAN BRIDGE (Elixir)     │ │
│  │  ┌─────────┐  ┌─────────────┐   │   │  ┌─────────┐  ┌─────────┐  │ │
│  │  │OpenTel. │  │ Prometheus  │   │   │  │Telemetry│  │PromEx   │  │ │
│  │  │  SDK    │  │  /metrics   │   │   │  │  Events │  │/metrics │  │ │
│  │  └────┬────┘  └──────┬──────┘   │   │  └────┬────┘  └────┬────┘  │ │
│  │       │              │          │   │       │            │       │ │
│  │  ┌────┴──────────────┴──────┐   │   │  ┌────┴────────────┴───┐   │ │
│  │  │    Application Metrics   │   │   │  │  Application Metrics │   │ │
│  │  └──────────────────────────┘   │   │  └─────────────────────┘   │ │
│  └─────────────────────────────────┘   └─────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## 部署监控栈

### 启动所有服务

```bash
cd monitoring
docker-compose -f docker-compose.monitoring.yml up -d
```

### 访问界面

| 服务 | URL | 默认凭证 |
|------|-----|----------|
| Grafana | http://localhost:3000 | admin / titan-admin-123 |
| Prometheus | http://localhost:9090 | - |
| Alertmanager | http://localhost:9093 | - |
| Jaeger UI | http://localhost:16686 | - |

### 数据源配置

Grafana 已自动配置以下数据源：
- **Prometheus** (默认) - 指标数据
- **Loki** - 日志聚合
- **Jaeger** - 分布式追踪
- **PostgreSQL** - 数据库查询

## 指标详情

### C# Core 指标

```csharp
// Counters
titan_weight_samples_total              // 处理的重量样本总数
titan_fsm_transitions_total             // FSM 状态转换次数
titan_print_jobs_total                  // 打印任务总数
titan_print_jobs_failed_total           // 失败的打印任务
titan_erp_sync_total                    // ERP 同步尝试次数
titan_erp_sync_failed_total             // 失败的 ERP 同步
titan_hardware_events_total             // 硬件事件总数

// Histograms
titan_weight_distribution               // 重量分布 (kg)
titan_print_duration_seconds            // 打印耗时
titan_erp_sync_duration_seconds         // ERP 同步耗时

// Gauges
titan_queue_depth                       // 当前队列深度
titan_device_status                     // 设备状态 (0-3)
```

### Elixir Bridge 指标

```elixir
# Counters
titan_device_connections_total          # 设备连接总数
titan_websocket_messages_received_total # WebSocket 接收消息数
titan_websocket_messages_sent_total     # WebSocket 发送消息数
titan_queue_messages_enqueued_total     # 入队消息数
titan_queue_messages_completed_total    # 完成消息数
titan_queue_messages_failed_total       # 失败消息数
titan_erp_sync_requests_total           # ERP 同步请求数
titan_telegram_commands_total           # Telegram 命令数

# Histograms
titan_websocket_message_processing_duration_seconds  # 消息处理耗时
titan_erp_sync_duration_seconds                      # ERP 同步耗时
titan_telegram_response_duration_seconds             # Telegram 响应耗时

# Gauges
titan_device_connections_active         # 活跃设备连接数
titan_queue_depth                       # 队列深度
titan_telegram_sessions_active          # Telegram 活跃会话数
```

## 告警规则

### 内置告警

| 告警名称 | 条件 | 严重程度 | 延迟 |
|----------|------|----------|------|
| DeviceOffline | 无设备连接 | warning | 1m |
| QueueBacklog | 队列 > 1000 | warning | 5m |
| QueueBacklogCritical | 队列 > 5000 | critical | 2m |
| ERPSyncFailureRate | 失败率 > 10% | warning | 5m |
| PrintJobFailures | 1小时内 > 10 失败 | warning | 0m |
| HighWebsocketLatency | P95 > 100ms | warning | 5m |
| HighMemoryUsage | 内存 > 512MB | warning | 5m |
| DatabaseConnectionFailure | DB 连接失败 | critical | 1m |

### 告警通知渠道

```yaml
# Alertmanager 配置
receivers:
  - critical-alerts:
    - Slack (#titan-critical)
    - Email (ops@accord.uz)
    - Telegram Bot
  
  - warning-alerts:
    - Slack (#titan-warnings)
```

## 仪表盘

### 1. Titan Overview (titan-overview)

系统整体视图，包含：
- 活跃设备数
- 队列深度
- 设备连接趋势
- 消息队列状态
- ERP 同步性能

### 2. Titan FSM & Batch Processing (titan-fsm)

批次处理详情：
- 当前 FSM 状态
- 状态转换频率
- 重量分布直方图
- 打印任务统计
- 活跃批次列表

### 3. Titan Hardware (titan-hardware)

硬件监控：
- 电子秤状态
- 打印机状态
- 实时重量 (Gauge)
- 重量历史趋势
- 硬件事件日志

### 4. Titan WebSocket & Messaging

通信监控：
- WebSocket 连接数
- 消息吞吐量
- 消息延迟热力图
- 消息类型分布

### 5. Titan System Resources

系统资源：
- 内存使用 (VM + 系统)
- Run Queue 长度
- CPU 使用率
- 磁盘 I/O

### 6. Titan Alerts

告警管理：
- 活跃告警列表
- 告警历史趋势

### 7. Titan Telegram Bot

Bot 使用统计：
- 活跃会话数
- 命令使用频率
- 响应时间分布

## 分布式追踪

### Jaeger 集成

```csharp
// C# - 自动追踪
using var activity = _tracingService.StartActivity("ProcessWeight", ActivityKind.Internal);
_tracingService.AddEvent(activity, "WeightStabilized", new Dictionary<string, object>
{
    ["weight"] = weight,
    ["stable"] = true
});
```

```elixir
# Elixir - 自动追踪
TitanBridge.OpenTelemetry.trace("process_message", %{type: "weight_record"}, fn ->
  # Your code here
end)
```

### 追踪视图

在 Jaeger UI (http://localhost:16686) 可以查看：
- 请求调用链
- 服务依赖图
- 延迟分析
- 错误追踪

## 日志聚合

### Loki 查询示例

```bash
# 查看 Titan Core 日志
{job="titan-core"}

# 查看特定设备日志
{job="titan-core"} |= "device_id=DEV-001"

# 查看错误日志
{job="titan-core"} |= "ERROR"

# 查看特定批次
{job="titan-core"} |= "batch_id=BATCH-001"

# 查看硬件事件
{job="titan-core"} |= "hardware"
```

### Grafana 日志面板

仪表盘中的 Logs 面板支持：
- 实时日志流
- 日志过滤
- 关键词高亮
- 上下文查看

## 性能调优指南

### Prometheus 配置

```yaml
# 根据负载调整
global:
  scrape_interval: 15s      # 采集间隔
  evaluation_interval: 15s  # 规则评估间隔
  
storage:
  tsdb:
    retention.time: 30d     # 数据保留时间
```

### Grafana 性能

```bash
# 增加缓存
docker run -e GF_CACHE_ENABLED=true grafana/grafana

# 限制数据源查询
docker run -e GF_DATAPROXY_TIMEOUT=30 grafana/grafana
```

### 高可用配置

```yaml
# docker-compose.ha.yml
services:
  prometheus-1:
    # Primary
  prometheus-2:
    # Secondary
  thanos-sidecar:
    # Long-term storage
  thanos-query:
    # Query federation
```

## 监控检查清单

### 部署前

- [ ] 配置正确的 scrape targets
- [ ] 设置告警规则
- [ ] 配置通知渠道 (Slack, Email, Telegram)
- [ ] 创建 Grafana 用户和权限

### 部署后

- [ ] 验证所有 targets UP
- [ ] 测试告警通知
- [ ] 确认仪表盘数据正常
- [ ] 检查日志收集
- [ ] 验证追踪数据

### 日常运维

- [ ] 检查磁盘空间 (Prometheus, Loki)
- [ ] 监控查询性能
- [ ] 审查告警频率
- [ ] 更新仪表盘

## 故障排查

### Prometheus 无法连接 Target

```bash
# 检查网络
curl http://titan-core:8080/metrics

# 检查防火墙
docker network inspect titan-monitoring

# 查看 Prometheus 日志
docker logs titan-prometheus
```

### Grafana 无数据

```bash
# 检查数据源
curl http://prometheus:9090/api/v1/targets

# 检查查询
curl 'http://prometheus:9090/api/v1/query?query=titan_device_connections_active'
```

### 告警不触发

```bash
# 检查告警规则
curl http://prometheus:9090/api/v1/rules

# 检查告警状态
curl http://prometheus:9090/api/v1/alerts

# 检查 Alertmanager
curl http://alertmanager:9093/api/v1/status
```

## 扩展阅读

- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [Grafana Dashboard Guide](https://grafana.com/docs/grafana/latest/dashboards/)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/)
- [Jaeger Architecture](https://www.jaegertracing.io/docs/1.52/architecture/)

## 下一步

### Phase 5: Production Deployment

1. **Kubernetes 部署**
   - Helm Charts
   - Operators
   - Ingress 配置

2. **高可用架构**
   - Prometheus HA
   - Grafana Cluster
   - 多区域部署

3. **安全加固**
   - TLS/SSL
   - 认证授权
   - 网络隔离
