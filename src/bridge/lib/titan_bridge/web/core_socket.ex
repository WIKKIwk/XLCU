defmodule TitanBridge.Web.CoreSocket do
  @moduledoc """
  WebSocket handler for C# Core agent communication.

  Protocol (JSON over WS):
    Client → Server:
      {type: "auth", device_id: "CORE-01", token: "..."}
      {type: "status", data: %{...}}          — device status update
      {type: "result", request_id, ok, data}  — command response
      {type: "event", data: %{...}}           — device event (weight, scan)
      {type: "pong"}                          — keepalive response

    Server → Client:
      {type: "auth", ok: true}
      {type: "hello", protocol: 1}
      {type: "command", request_id, name, payload}
      {type: "ping"}                          — every 15s

  Flow: connect → auth → registered in CoreHub → bidirectional → disconnect
  """
  @behaviour :cowboy_websocket
  require Logger

  alias TitanBridge.CoreHub

  def init(req, _opts) do
    {:cowboy_websocket, req, %{authed: false, device_id: nil, last_pong: nil}}
  end

  def websocket_init(state) do
    schedule_ping()
    {:ok, state}
  end

  def websocket_handle({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"type" => "auth"} = data} ->
        handle_auth(data, state)

      {:ok, %{"type" => "status", "data" => status}} when state.authed ->
        CoreHub.update_status(state.device_id, status)
        {:ok, state}

      {:ok, %{"type" => "result", "request_id" => request_id} = data} when state.authed ->
        ok = data["ok"] != false
        payload = data["data"] || data["error"] || %{}
        CoreHub.handle_result(state.device_id, request_id, ok, payload)
        {:ok, state}

      {:ok, %{"type" => "event", "data" => event}} when state.authed and is_map(event) ->
        CoreHub.handle_event(state.device_id, event)
        {:ok, state}

      {:ok, %{"type" => "pong"}} ->
        {:ok, %{state | last_pong: DateTime.utc_now()}}

      {:ok, %{"type" => "hello"}} ->
        {:ok, state}

      {:ok, _} ->
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  def websocket_info({:core_command, request_id, name, payload}, state) do
    msg = %{
      type: "command",
      request_id: request_id,
      name: name,
      payload: payload || %{}
    }
    {:reply, {:text, Jason.encode!(msg)}, state}
  end

  def websocket_info(:send_hello, state) do
    if state.authed do
      msg = %{
        type: "hello",
        protocol: 1,
        server_time: DateTime.utc_now()
      }
      {:reply, {:text, Jason.encode!(msg)}, state}
    else
      {:ok, state}
    end
  end

  def websocket_info(:ping, state) do
    schedule_ping()
    if state.authed do
      {:reply, {:text, Jason.encode!(%{type: "ping"})}, state}
    else
      {:ok, state}
    end
  end

  def websocket_info(_info, state), do: {:ok, state}

  def terminate(_reason, _req, state) do
    case state do
      %{device_id: device_id} when not is_nil(device_id) ->
        CoreHub.unregister(self())

      _ ->
        :ok
    end
    :ok
  end

  defp handle_auth(%{"device_id" => device_id, "token" => token} = data, state) do
    if authorized?(token) do
      _ = CoreHub.register(device_id, self(), data)
      reply = %{"type" => "auth", "ok" => true, "device_id" => device_id}
      send(self(), :send_hello)
      {:reply, {:text, Jason.encode!(reply)}, %{state | authed: true, device_id: device_id}}
    else
      reply = %{"type" => "auth", "ok" => false, "error" => "unauthorized"}
      {:reply, {:close, 1008, Jason.encode!(reply)}, state}
    end
  end

  defp handle_auth(_data, state) do
    reply = %{"type" => "auth", "ok" => false, "error" => "invalid_auth"}
    {:reply, {:close, 1008, Jason.encode!(reply)}, state}
  end

  defp authorized?(token) when is_binary(token) do
    secret = System.get_env("LCE_CORE_TOKEN") || ""
    if String.trim(secret) == "" do
      not production?()
    else
      Plug.Crypto.secure_compare(secret, token)
    end
  end

  defp authorized?(_), do: false

  defp production? do
    Application.get_env(:titan_bridge, :env) == :prod or
      System.get_env("MIX_ENV") == "prod"
  end

  defp schedule_ping do
    interval = Application.get_env(:titan_bridge, __MODULE__)[:ping_interval_ms] || 15000
    Process.send_after(self(), :ping, interval)
  end
end
