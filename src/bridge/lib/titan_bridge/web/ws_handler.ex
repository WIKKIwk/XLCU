defmodule TitanBridge.Web.WsHandler do
  @moduledoc """
  Generic WebSocket handler at /ws — broadcasts cache version updates.

  On connect: sends current cache versions.
  Then: forwards all Realtime events to client as JSON frames.
  Read-only — client messages are ignored.
  """
  @behaviour :cowboy_websocket

  alias TitanBridge.{Cache, Realtime}

  def init(req, _opts) do
    {:cowboy_websocket, req, %{}}
  end

  def websocket_init(state) do
    Realtime.subscribe(self())
    payload = %{
      type: "hello",
      versions: %{
        items: Cache.version(:items),
        warehouses: Cache.version(:warehouses),
        bins: Cache.version(:bins),
        stock_drafts: Cache.version(:stock_drafts)
      }
    }
    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  def websocket_handle({:text, _msg}, state) do
    {:ok, state}
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  def websocket_info({:realtime, payload}, state) do
    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, _state) do
    Realtime.unsubscribe(self())
    :ok
  end
end
