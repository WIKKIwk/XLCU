# ============================================
# TITAN BRIDGE - Configuration Files
# ============================================
# File: titan_bridge/config/config.exs
# ============================================
import Config

config :titan_bridge,
  ecto_repos: [TitanBridge.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  # Security - generate strong key in production
  session_encryption_key:
    System.get_env("SESSION_ENCRYPTION_KEY") || :crypto.strong_rand_bytes(32),
  api_token: System.get_env("TITAN_API_TOKEN") || "dev-token-change-in-production"

# Database
config :titan_bridge, TitanBridge.Repo,
  database: System.get_env("DB_NAME") || "titan_bridge_dev",
  username: System.get_env("DB_USER") || "postgres",
  password: System.get_env("DB_PASSWORD") || "postgres",
  hostname: System.get_env("DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE") || "10")

# Phoenix
config :titan_bridge, TitanBridgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: TitanBridgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TitanBridge.PubSub,
  live_view: [signing_salt: "change-in-production"]

# Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger,
  level: :info

# Telegram Bot
config :ex_gram,
  token: System.get_env("TELEGRAM_BOT_TOKEN") || "",
  username: System.get_env("TELEGRAM_BOT_USERNAME") || "titan_core_bot"

config :titan_bridge, TitanBridge.Telegram.Bot,
  username: System.get_env("TELEGRAM_BOT_USERNAME") || "titan_core_bot",
  token: System.get_env("TELEGRAM_BOT_TOKEN") || "",
  webhook_url: System.get_env("TELEGRAM_WEBHOOK_URL") || nil,
  webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET") || nil

# ERPNext
config :titan_bridge, :erp,
  url: System.get_env("ERP_URL") || "http://localhost:8000",
  api_key: System.get_env("ERP_API_KEY") || "",
  api_secret: System.get_env("ERP_API_SECRET") || ""

# Cache
config :titan_bridge, :cache,
  ttl_seconds: String.to_integer(System.get_env("CACHE_TTL_SECONDS") || "300")

# Import environment specific config
import_config "#{config_env()}.exs"

# ============================================
# File: titan_bridge/config/runtime.exs
# ============================================
import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  config :titan_bridge, TitanBridge.Repo,
    ssl: true,
    ssl_opts: [verify: :verify_none],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :titan_bridge, TitanBridgeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :titan_bridge, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Telegram Bot Production Settings
  config :ex_gram, :token, System.get_env("TELEGRAM_BOT_TOKEN")

  config :titan_bridge, TitanBridge.Telegram.Bot,
    webhook_url: System.get_env("TELEGRAM_WEBHOOK_URL"),
    webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET")
end

# ============================================
# File: titan_bridge/config/dev.exs
# ============================================
import Config

config :titan_bridge, TitanBridge.Repo,
  database: "titan_bridge_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :titan_bridge, TitanBridgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-secret-key-base-change-in-production-dev-secret-key-base",
  watchers: []

config :titan_bridge, dev_routes: true

config :logger, :console, format: "[$level] $message\n", level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

# ============================================
# File: titan_bridge/config/prod.exs
# ============================================
import Config

config :titan_bridge, TitanBridgeWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

# ============================================
# File: titan_bridge/config/test.exs
# ============================================
import Config

config :titan_bridge, TitanBridge.Repo,
  database: "titan_bridge_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :titan_bridge, TitanBridgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-secret-key-base-test-secret-key-base-test-secret-key-base",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# ============================================
# File: titan_bridge/priv/repo/migrations/001_create_devices.exs
# ============================================
defmodule TitanBridge.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:device_id, :string, null: false)
      add(:name, :string)
      add(:location, :string)
      add(:status, :string, default: "offline")
      add(:last_seen_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})
      add(:capabilities, {:array, :string}, default: [])
      add(:auth_token_hash, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:devices, [:device_id]))
    create(index(:devices, [:status]))
  end
end

# ============================================
# File: titan_bridge/priv/repo/migrations/002_create_events.exs
# ============================================
defmodule TitanBridge.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:event_type, :string, null: false)
      add(:event_id, :string, null: false)
      add(:payload, :map, null: false)
      add(:processed_at, :utc_datetime_usec)
      add(:synced_to_erp, :boolean, default: false)
      add(:sync_attempts, :integer, default: 0)
      add(:error_message, :text)
      add(:device_id, references(:devices, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:events, [:event_id]))
    create(index(:events, [:device_id]))
    create(index(:events, [:synced_to_erp]))
    create(index(:events, [:event_type]))
  end
end

# ============================================
# File: titan_bridge/priv/repo/migrations/003_create_sync_records.exs
# ============================================
defmodule TitanBridge.Repo.Migrations.CreateSyncRecords do
  use Ecto.Migration

  def change do
    create table(:sync_records, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:record_type, :string, null: false)
      add(:erp_endpoint, :string, null: false)
      add(:payload, :map, null: false)
      add(:status, :string, default: "pending")
      add(:priority, :integer, default: 5)
      add(:retry_count, :integer, default: 0)
      add(:next_retry_at, :utc_datetime_usec)
      add(:error_log, {:array, :map}, default: [])
      add(:erp_response, :map)
      add(:device_id, references(:devices, type: :binary_id, on_delete: :nilify_all))

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sync_records, [:status]))
    create(index(:sync_records, [:device_id]))
    create(index(:sync_records, [:next_retry_at]))
    create(index(:sync_records, [:priority, :inserted_at]))
  end
end

# ============================================
# File: titan_bridge/priv/repo/seeds.exs
# ============================================
alias TitanBridge.Repo
alias TitanBridge.Devices.Device

# Insert sample device for development
unless Repo.get_by(Device, device_id: "DEV-DEMO-001") do
  %Device{}
  |> Device.changeset(%{
    device_id: "DEV-DEMO-001",
    name: "Demo Device",
    location: "Warehouse A",
    status: :offline,
    capabilities: ["zebra_print", "rfid_encode", "scale_read"]
  })
  |> Repo.insert!()

  IO.puts("Created demo device: DEV-DEMO-001")
end

IO.puts("Seeds completed!")
