defmodule TitanBridge.RfidListener do
  @moduledoc """
  Polls RFID Node.js server for new tag reads.

  Every ~1s checks GET /api/status for lastTag.epcId.
  When a new EPC is detected, notifies all subscribers via message.
  Subscribers register with subscribe/1 and unsubscribe with unsubscribe/1.
  """
  use GenServer
  require Logger

  alias TitanBridge.SettingsStore

  @poll_default_ms 1000
  @event_dedupe_default_ms 300

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def subscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  def unsubscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:unsubscribe, pid})
  end

  @impl true
  def init(_) do
    schedule_poll(poll_interval())
    {:ok, %{subscribers: MapSet.new(), last_epc: nil, last_seen_at: nil, last_emitted_ms: 0}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, {pid, ref})}}
  end

  @impl true
  def handle_call({:unsubscribe, pid}, _from, state) do
    {removed, remaining} =
      Enum.split_with(state.subscribers, fn {p, _ref} -> p == pid end)

    Enum.each(removed, fn {_p, ref} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | subscribers: MapSet.new(remaining)}}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = poll_rfid(state)
    schedule_poll(poll_interval())
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    remaining =
      state.subscribers
      |> Enum.reject(fn {p, _ref} -> p == pid end)
      |> MapSet.new()

    {:noreply, %{state | subscribers: remaining}}
  end

  defp poll_rfid(state) do
    case fetch_last_tag() do
      {:ok, epc, seen_at} when is_binary(epc) and epc != "" ->
        now_ms = System.monotonic_time(:millisecond)
        dedupe_ms = event_dedupe_ms()
        elapsed = now_ms - (state.last_emitted_ms || 0)

        should_emit? =
          cond do
            epc != state.last_epc ->
              true

            # Same EPC: suppress high-frequency repeats even if reader updates seenAt constantly.
            elapsed < dedupe_ms ->
              false

            true ->
              seen_at != state.last_seen_at
          end

        if should_emit? do
          notify_subscribers(state.subscribers, epc)
          %{state | last_epc: epc, last_seen_at: seen_at, last_emitted_ms: now_ms}
        else
          state
        end

      _ ->
        state
    end
  end

  defp fetch_last_tag do
    settings = SettingsStore.get()
    rfid_url = settings && settings.rfid_url

    if is_binary(rfid_url) and String.trim(rfid_url) != "" do
      base = String.trim_trailing(rfid_url, "/")
      url = base <> "/api/status"

      case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch, receive_timeout: 5000) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, %{"status" => %{"lastTag" => %{"epcId" => epc} = tag}}} when is_binary(epc) ->
              {:ok, normalize_epc(epc), tag["seenAt"]}

            {:ok, _} ->
              :no_tag

            {:error, _} ->
              :no_tag
          end

        {:error, reason} ->
          Logger.debug("RFID poll error: #{inspect(reason)}")
          :error
      end
    else
      :not_configured
    end
  end

  defp normalize_epc(raw) do
    raw
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^0-9A-F]/, "")
  end

  defp notify_subscribers(subscribers, epc) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:rfid_tag, epc})
    end)
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, @poll_default_ms)
  end

  defp event_dedupe_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_EVENT_DEDUPE_MS") || "")) do
      {n, _} when n >= 0 and n <= 5_000 -> n
      _ -> @event_dedupe_default_ms
    end
  end
end
