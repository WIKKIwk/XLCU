# TITAN Bridge — runtime configuration
# Evaluated at boot (not compile time). Env vars read here.

import Config

# --- Database ---
# DATABASE_URL format: ecto://user:pass@host:port/dbname
database_url = System.get_env("DATABASE_URL") ||
  "ecto://titan:titan_secret@localhost/titan_bridge_dev"
sql_log =
  case String.downcase(System.get_env("LCE_SQL_LOG", "false")) do
    "1" -> :debug
    "true" -> :debug
    "yes" -> :debug
    "on" -> :debug
    _ -> false
  end

config :titan_bridge, TitanBridge.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  log: sql_log

# --- Child process configuration ---
# Bridge spawns zebra_v1 and rfid as OS child processes.
# LCE_ROOT_DIR: project root (auto-detected if not set)
# LCE_ZEBRA_DIR / LCE_RFID_DIR: override child directories

root_dir =
  System.get_env("LCE_ROOT_DIR")
  || Path.expand("../../../../", __DIR__)

bash = System.find_executable("bash") || "/bin/bash"
zebra_dir = System.get_env("LCE_ZEBRA_DIR") || Path.join(root_dir, "zebra_v1")
rfid_dir = System.get_env("LCE_RFID_DIR") || Path.join(root_dir, "rfid")

zebra_port = System.get_env("LCE_ZEBRA_PORT") || "18000"
rfid_port = System.get_env("LCE_RFID_PORT") || "8787"
zebra_host = System.get_env("LCE_ZEBRA_HOST") || "0.0.0.0"
rfid_host = System.get_env("LCE_RFID_HOST") || "0.0.0.0"

children = [
  # Zebra label printer bridge (C#/.NET)
  %{
    name: :zebra,
    cmd: bash,
    args: ["run.sh"],
    cwd: zebra_dir,
    env: [
      {"XDG_CACHE_HOME", Path.join(zebra_dir, ".cache")},
      {"ZEBRA_WEB_HOST", zebra_host},
      {"ZEBRA_WEB_PORT", zebra_port},
      {"ZEBRA_NO_TUI", "1"}
    ]
  },
  # RFID reader bridge (Java)
  %{
    name: :rfid,
    cmd: bash,
    args: ["start-web.sh"],
    cwd: rfid_dir,
    env: [
      {"SKIP_BUILD_BRIDGE", "1"},
      {"RFID_NO_TUI", "1"},
      {"HOST", rfid_host},
      {"PORT", rfid_port}
    ]
  }
]

config :titan_bridge, :children, children
