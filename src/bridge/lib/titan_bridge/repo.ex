defmodule TitanBridge.Repo do
  use Ecto.Repo,
    otp_app: :titan_bridge,
    adapter: Ecto.Adapters.Postgres
end
