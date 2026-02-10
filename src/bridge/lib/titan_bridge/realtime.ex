defmodule TitanBridge.Realtime do
  @moduledoc """
  Simple PubSub — broadcasts cache updates to subscribed WebSocket clients.

  subscribe/1 and unsubscribe/1 manage per-pid subscriptions.
  broadcast/1 sends {:realtime, payload} to all subscribers.
  """
  use GenServer

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def subscribe(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  def unsubscribe(pid) when is_pid(pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  def broadcast(payload) do
    GenServer.cast(__MODULE__, {:broadcast, payload})
  end

  @impl true
  def init(_state) do
    {:ok, %{subs: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, put_sub(state, pid, ref)}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, drop_sub(state, pid)}
  end

  @impl true
  def handle_cast({:broadcast, payload}, state) do
    Enum.each(state.subs, fn {pid, _ref} ->
      send(pid, {:realtime, payload})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.subs do
      %{^pid => ^ref} -> {:noreply, drop_sub(state, pid)}
      _ -> {:noreply, state}
    end
  end

  defp put_sub(state, pid, ref) do
    %{state | subs: Map.put(state.subs, pid, ref)}
  end

  defp drop_sub(state, pid) do
    case Map.pop(state.subs, pid) do
      {nil, subs} ->
        %{state | subs: subs}

      {ref, subs} ->
        Process.demonitor(ref, [:flush])
        %{state | subs: subs}
    end
  end
end
