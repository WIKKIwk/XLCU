import Config

config :titan_bridge, env: :prod

config :titan_bridge, TitanBridge.Repo, pool_size: 10
