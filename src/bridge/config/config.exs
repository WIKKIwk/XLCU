# TITAN Bridge — compile-time configuration
# Runtime overrides: see runtime.exs
# Environment-specific: see dev.exs / prod.exs

import Config

# --- Database ---
config :titan_bridge, TitanBridge.Repo,
  pool_size: 10,
  ssl: false

config :titan_bridge,
  ecto_repos: [TitanBridge.Repo],
  http_port: String.to_integer(System.get_env("LCE_HTTP_PORT", "4000"))

# --- Telegram Bot ---
# poll_interval_ms: delay between long-poll cycles (ms)
# poll_timeout_sec: Telegram API long-poll timeout (seconds)
config :titan_bridge, TitanBridge.Telegram.Bot,
  poll_interval_ms: String.to_integer(System.get_env("LCE_TG_POLL_MS", "1200")),
  poll_timeout_sec: String.to_integer(System.get_env("LCE_TG_TIMEOUT_SEC", "25"))

# --- RFID Telegram Bot ---
config :titan_bridge, TitanBridge.Telegram.RfidBot,
  poll_interval_ms: String.to_integer(System.get_env("LCE_RFID_TG_POLL_MS", "1200")),
  poll_timeout_sec: String.to_integer(System.get_env("LCE_RFID_TG_TIMEOUT_SEC", "25"))

# --- RFID Listener ---
config :titan_bridge, TitanBridge.RfidListener,
  poll_interval_ms: String.to_integer(System.get_env("LCE_RFID_LISTEN_MS", "250"))

# --- ERP Sync ---
# poll_interval_ms: how often to sync with ERPNext (ms)
# full_refresh_every: do a full (not incremental) sync every N cycles
config :titan_bridge, TitanBridge.ErpSyncWorker,
  poll_interval_ms: String.to_integer(System.get_env("LCE_SYNC_INTERVAL_MS", "10000")),
  full_refresh_every: String.to_integer(System.get_env("LCE_SYNC_FULL_EVERY", "6"))

# --- Core Device Hub ---
config :titan_bridge, TitanBridge.CoreHub,
  retry_count: String.to_integer(System.get_env("LCE_CORE_RETRY", "1"))

# --- Core WebSocket ---
config :titan_bridge, TitanBridge.Web.CoreSocket,
  ping_interval_ms: String.to_integer(System.get_env("LCE_CORE_PING_MS", "15000"))

# --- Logging ---
config :logger, :console, format: "$time $metadata[$level] $message\n"

# Load environment-specific config (dev/test/prod).
import_config "#{config_env()}.exs"
