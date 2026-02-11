defmodule TitanBridge.Application do
  @moduledoc """
  TITAN Bridge — OTP Application entry point.

  Supervision tree (one_for_one):

      Vault          - AES-GCM encryption for DB tokens
      Repo           - PostgreSQL via Ecto
      Finch          - HTTP client pool (ERP API calls)
      Realtime       - PubSub for WebSocket broadcasts
      CoreHub        - Connected device registry + command routing
      ErpSyncWorker  - Periodic ERPNext data sync (items, warehouses, bins)
      Children       - OS process manager (spawns zebra_v1, rfid)
      Telegram.Bot   - Telegram long-poll bot (primary operator UI)
      RfidListener   - RFID tag polling (detects scanned tags)
      Telegram.RfidBot - RFID Telegram bot (auto-submit drafts)
      Plug.Cowboy    - HTTP/WS server on :4000
  """
  use Application

  def start(_type, _args) do
    children = [
      TitanBridge.Vault,
      TitanBridge.Repo,
      {Finch, name: TitanBridgeFinch},
      TitanBridge.Realtime,
      TitanBridge.CoreHub,
      TitanBridge.ErpSyncWorker,
      TitanBridge.Children,
      TitanBridge.Telegram.Bot
    ]

    children =
      if TitanBridge.ChildrenTarget.enabled?("rfid") do
        children ++ [TitanBridge.RfidListener, TitanBridge.Telegram.RfidBot]
      else
        children
      end

    children =
      children ++ [
        {Plug.Cowboy, scheme: :http, plug: TitanBridge.Web.Router, options: [port: http_port()]}
      ]

    opts = [strategy: :one_for_one, name: TitanBridge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_port do
    Application.get_env(:titan_bridge, :http_port, 4000)
  end
end
