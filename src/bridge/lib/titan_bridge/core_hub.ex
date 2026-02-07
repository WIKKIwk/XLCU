defmodule TitanBridge.CoreHub do
  @moduledoc """
  Registry and command router for connected C# Core devices.

  Devices connect via WebSocket (/ws/core) and register with device_id.
  CoreHub tracks each device's pid, capabilities, and last status.

  Commands flow: Telegram bot → CoreHub.send_command/3 → WebSocket → Core
  Results flow:  Core → WebSocket → CoreHub.handle_result/4 → caller

  Supports request/reply with configurable timeout and retry.
  """
  use GenServer
  require Logger

  @type device_info :: %{
          pid: pid(),
          capabilities: list(),
          status: map() | nil,
          connected_at: DateTime.t()
        }

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(device_id, pid, meta \\ %{}) when is_binary(device_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, device_id, pid, meta})
  end

  def unregister(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unregister, pid})
  end

  def list_devices do
    GenServer.call(__MODULE__, :list_devices)
  end

  def update_status(device_id, status) when is_binary(device_id) and is_map(status) do
    GenServer.cast(__MODULE__, {:status, device_id, status})
  end

  def handle_result(device_id, request_id, ok, data) do
    GenServer.cast(__MODULE__, {:result, device_id, request_id, ok, data})
  end

  def command(device_id, name, payload \\ %{}, timeout_ms \\ 5000) do
    retries = if retryable?(name), do: max_retries(), else: 0
    call_timeout = timeout_ms * (retries + 1) + 1000
    GenServer.call(__MODULE__, {:command, device_id, name, payload, timeout_ms, retries}, call_timeout)
  end

  def handle_event(device_id, event) when is_binary(device_id) and is_map(event) do
    GenServer.cast(__MODULE__, {:event, device_id, event})
  end

  @impl true
  def init(_state) do
    {:ok, %{devices: %{}, pids: %{}, pending: %{}}}
  end

  @impl true
  def handle_call({:register, device_id, pid, meta}, _from, state) do
    ref = Process.monitor(pid)
    capabilities = meta["capabilities"] || meta[:capabilities] || []
    info = %{pid: pid, capabilities: capabilities, status: nil, connected_at: DateTime.utc_now()}

    state =
      state
      |> drop_device(device_id)
      |> put_device(device_id, pid, ref, info)

    Logger.info("[core_hub] device connected #{device_id}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_devices, _from, state) do
    devices =
      state.devices
      |> Enum.map(fn {id, info} ->
        info
        |> Map.drop([:pid, :monitor_ref])
        |> Map.merge(%{device_id: id})
      end)

    {:reply, devices, state}
  end

  @impl true
  def handle_call({:command, device_id, name, payload, timeout_ms, retries}, from, state) do
    {target_id, info} = resolve_device(state, device_id)

    if info == nil do
      {:reply, {:error, :offline}, state}
    else
      request_id = gen_request_id()
      send(info.pid, {:core_command, request_id, name, payload})
      timer = Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)
      pending = Map.put(state.pending, request_id, %{
        from: from,
        timer: timer,
        device_id: target_id,
        name: name,
        payload: payload,
        timeout_ms: timeout_ms,
        attempts: 0,
        retries: retries
      })
      {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_cast({:unregister, pid}, state) do
    {:noreply, drop_pid(state, pid)}
  end

  @impl true
  def handle_cast({:status, device_id, status}, state) do
    state = update_device(state, device_id, fn info -> Map.put(info, :status, status) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:event, device_id, event}, state) do
    state = update_device(state, device_id, fn info -> Map.put(info, :last_event, event) end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:result, _device_id, request_id, ok, data}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}
      {%{from: from, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, if(ok, do: {:ok, data}, else: {:error, data}))
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, pending} -> {:noreply, %{state | pending: pending}}
      {entry, pending} ->
        handle_timeout(request_id, entry, %{state | pending: pending})
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_pid(state, pid)}
  end

  defp resolve_device(state, nil) do
    case Enum.at(state.devices, 0) do
      nil -> {nil, nil}
      {id, info} -> {id, info}
    end
  end

  defp resolve_device(state, device_id) do
    {device_id, Map.get(state.devices, device_id)}
  end

  defp drop_device(state, device_id) do
    case Map.get(state.devices, device_id) do
      nil -> state
      %{pid: pid} -> drop_pid(state, pid)
    end
  end

  defp drop_pid(state, pid) do
    case Map.pop(state.pids, pid) do
      {nil, pids} -> %{state | pids: pids}
      {device_id, pids} ->
        Logger.info("[core_hub] device disconnected #{device_id}")
        pending = cancel_pending_for_device(state.pending, device_id)
        devices = Map.delete(state.devices, device_id)
        %{state | devices: devices, pids: pids, pending: pending}
    end
  end

  defp cancel_pending_for_device(pending, device_id) do
    Enum.reduce(pending, %{}, fn {req, entry}, acc ->
      if entry.device_id == device_id do
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:error, :device_disconnected})
        acc
      else
        Map.put(acc, req, entry)
      end
    end)
  end

  defp handle_timeout(request_id, entry, state) do
    if entry.attempts < entry.retries do
      case Map.get(state.devices, entry.device_id) do
        nil ->
          GenServer.reply(entry.from, {:error, :offline})
          {:noreply, state}
        info ->
          send(info.pid, {:core_command, request_id, entry.name, entry.payload})
          timer = Process.send_after(self(), {:request_timeout, request_id}, entry.timeout_ms)
          updated = %{entry | attempts: entry.attempts + 1, timer: timer}
          {:noreply, %{state | pending: Map.put(state.pending, request_id, updated)}}
      end
    else
      GenServer.reply(entry.from, {:error, :timeout})
      {:noreply, state}
    end
  end

  defp max_retries do
    Application.get_env(:titan_bridge, __MODULE__)[:retry_count] || 1
  end

  defp retryable?(name) when is_binary(name) do
    name in ["scale_read", "health", "status"]
  end
  defp retryable?(_), do: false

  defp put_device(state, device_id, pid, ref, info) do
    devices = Map.put(state.devices, device_id, Map.put(info, :monitor_ref, ref))
    pids = Map.put(state.pids, pid, device_id)
    %{state | devices: devices, pids: pids}
  end

  defp update_device(state, device_id, fun) do
    case Map.get(state.devices, device_id) do
      nil -> state
      info ->
        devices = Map.put(state.devices, device_id, fun.(info))
        %{state | devices: devices}
    end
  end

  defp gen_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
