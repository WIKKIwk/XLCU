defmodule TitanBridge.Telegram.Bot do
  @moduledoc """
  Telegram bot — PRIMARY operator interface for the TITAN system.

  Runs as GenServer with long-polling. Uses two ETS tables for per-chat state:
    :tg_state — conversation state machine (e.g. "awaiting_product")
    :tg_temp  — temporary data during multi-step flows (selected product, etc.)

  ## Operator workflow (via Telegram)

      /start          → setup wizard: ERP URL → API key → API secret
      /batch start    → select product (inline query from ERPNext cache)
                      → select warehouse (filtered by product)
                      → scale gives weight → confirm
                      → prints RFID label → creates Stock Entry Draft
      /batch stop     → end current batch session
      /status         → show connected devices and system state
      /config         → show current settings (tokens masked)

  ## State machine per chat_id

      idle
        → "awaiting_erp_url"  (after /start)
        → "awaiting_erp_key"  → "awaiting_erp_secret"
        → "awaiting_product"  (after /batch start)
        → "awaiting_warehouse"
        → "awaiting_weight"
        → "confirming_print"
        → idle

  Token is read from SettingsStore on each poll cycle — no restart needed
  after configuration change.
  """
  use GenServer
  require Logger

  alias TitanBridge.{
    Cache,
    ChildrenTarget,
    CoreHub,
    ErpClient,
    ErpSyncWorker,
    EpcGenerator,
    SettingsStore,
    SyncState
  }

  alias TitanBridge.Telegram.{ChatState, SetupUtils, Transport}

  @state_table :tg_state
  @temp_table :tg_temp
  @products_cache_ttl_ms 60_000
  @warehouses_cache_ttl_ms 60_000

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @impl true
  def init(state) do
    ChatState.init_tables!(@state_table, @temp_table)
    schedule_poll(0)
    schedule_batch_watchdog(batch_watchdog_interval_ms())
    {:ok, Map.put(state, :poll_inflight, false)}
  end

  @impl true
  def handle_cast(:reload, state) do
    schedule_poll(0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:batch_next, token, chat_id, product_id}, state) do
    if ensure_batch_loop_active?(chat_id, product_id) do
      begin_weight_flow(token, chat_id, product_id)
    else
      Logger.warning(
        "[batch] loop skipped chat=#{chat_id} product=#{inspect(product_id)} " <>
          "state=#{inspect(get_state(chat_id))} active=#{inspect(get_temp(chat_id, "batch_active"))}"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:batch_draft_result, chat_id, _product_id, _weight, _epc, result}, state) do
    case result do
      :ok ->
        put_temp(chat_id, "batch_draft_fail_count", 0)

      {:error, reason} ->
        fail_count = (get_temp(chat_id, "batch_draft_fail_count") || 0) + 1
        put_temp(chat_id, "batch_draft_fail_count", fail_count)

        if rem(fail_count, 5) == 1 do
          Logger.warning("batch async draft failed ##{fail_count}: #{inspect(reason)}")

          case telegram_token() do
            token when is_binary(token) and token != "" ->
              send_message(
                token,
                chat_id,
                "Draft xato: #{ErpClient.human_error(reason)}\nBatch davom etadi."
              )

            _ ->
              :ok
          end
        end
    end

    {:noreply, state}
  end

  def handle_info(:poll, state) do
    state =
      case SettingsStore.get() do
        %{telegram_token: token} when is_binary(token) and byte_size(token) > 0 ->
          maybe_start_poll_task(state, token)

        _ ->
          Map.put(state, :poll_inflight, false)
      end

    schedule_poll(poll_interval())
    {:noreply, state}
  end

  @impl true
  def handle_info(:batch_watchdog, state) do
    recover_stalled_batch_loops()
    schedule_batch_watchdog(batch_watchdog_interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll_done, state) do
    {:noreply, Map.put(state, :poll_inflight, false)}
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__)[:poll_interval_ms] || 1200
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp maybe_start_poll_task(state, token) do
    if Map.get(state, :poll_inflight, false) do
      state
    else
      parent = self()

      Task.start(fn ->
        try do
          poll_updates(token)
        rescue
          err ->
            Logger.warning("Telegram poll task crashed: #{inspect(err)}")
        catch
          kind, reason ->
            Logger.warning("Telegram poll task failed: #{inspect({kind, reason})}")
        after
          send(parent, :poll_done)
        end
      end)

      Map.put(state, :poll_inflight, true)
    end
  end

  defp poll_updates(token) do
    case Transport.get_updates(token, get_offset(), poll_timeout()) do
      {:ok, updates} ->
        handle_updates(token, %{"ok" => true, "result" => updates})

      {:error, {:http_error, status, body}} ->
        Logger.warning("Telegram poll failed: #{status} #{body}")

      {:error, err} ->
        Logger.warning("Telegram poll error: #{inspect(err)}")
    end
  end

  defp poll_timeout do
    Application.get_env(:titan_bridge, __MODULE__)[:poll_timeout_sec] || 25
  end

  defp handle_updates(token, %{"ok" => true, "result" => updates}) do
    Enum.each(updates, fn update ->
      set_offset(update)
      handle_update(token, update)
    end)
  end

  defp handle_updates(_, _), do: :ok

  defp handle_update(token, %{"message" => message}) do
    chat_id = message["chat"]["id"]
    text = String.trim(message["text"] || "")
    msg_id = message["message_id"]
    user = message["from"] || %{}

    cond do
      text == "/start" or text == "/reset" ->
        delete_message(token, chat_id, msg_id)
        # /start should ALWAYS allow re-configuring ERP settings. We only clear ERP-related
        # fields (keeping Telegram token + child URLs) and purge caches to avoid stale data.
        _ = SettingsStore.upsert(%{erp_url: nil, erp_token: nil, warehouse: nil})
        _ = SyncState.reset_all()
        _ = Cache.purge_all()

        delete_flow_msg(token, chat_id)
        clear_temp(chat_id)
        set_state(chat_id, "awaiting_erp_url")
        setup_prompt(token, chat_id, "ERP manzilini kiriting:")

      text == "/batch" or text == "/batch start" ->
        delete_message(token, chat_id, msg_id)
        send_batch_prompt(token, chat_id)

      text == "/batch stop" or text == "/stop" ->
        delete_message(token, chat_id, msg_id)
        stop_batch(token, chat_id)

      String.starts_with?(text, "product:") ->
        delete_message(token, chat_id, msg_id)
        product_id = String.replace_prefix(text, "product:", "")
        handle_product_selection(token, chat_id, String.trim(product_id))

      String.starts_with?(text, "warehouse:") ->
        delete_message(token, chat_id, msg_id)
        warehouse = String.replace_prefix(text, "warehouse:", "") |> String.trim()
        handle_warehouse_selection(token, chat_id, warehouse)

      text != "" ->
        handle_state_input(token, chat_id, text, msg_id, user)

      true ->
        :ok
    end
  end

  defp handle_update(token, %{"inline_query" => inline_query}) do
    query_id = inline_query["id"]
    query_text = String.trim(inline_query["query"] || "")
    from = inline_query["from"] || %{}
    chat_id = from["id"]
    answer_inline_query(token, query_id, query_text, chat_id)
  end

  defp handle_update(token, %{"callback_query" => cb}) do
    chat_id = cb["message"]["chat"]["id"]
    cb_id = cb["id"]
    data = cb["data"] || ""

    case data do
      "retry_batch" ->
        answer_callback(token, cb_id, "Tekshirilmoqda...")
        delete_message(token, chat_id, cb["message"]["message_id"])
        send_batch_prompt(token, chat_id)

      _ ->
        answer_callback(token, cb_id)
    end
  end

  defp handle_update(_token, _update), do: :ok

  defp handle_state_input(token, chat_id, text, msg_id, user) do
    case get_state(chat_id) do
      "awaiting_erp_url" ->
        delete_message(token, chat_id, msg_id)
        SettingsStore.upsert(%{erp_url: normalize_erp_url(text)})
        set_state(chat_id, "awaiting_api_key")
        setup_prompt(token, chat_id, "ERP saqlandi. Admin API KEY ni kiriting (15 belgi):")

      "awaiting_api_key" ->
        delete_message(token, chat_id, msg_id)
        trimmed = String.trim(text)

        if valid_api_credential?(trimmed) do
          put_temp(chat_id, "api_key", trimmed)
          set_state(chat_id, "awaiting_api_secret")

          setup_prompt(
            token,
            chat_id,
            "API KEY qabul qilindi. Endi API SECRET ni kiriting (15 belgi):"
          )
        else
          setup_prompt(
            token,
            chat_id,
            "API KEY noto'g'ri (15 ta harf/raqam kerak). Qaytadan kiriting:"
          )
        end

      "awaiting_api_secret" ->
        delete_message(token, chat_id, msg_id)
        trimmed = String.trim(text)

        case get_temp(chat_id, "api_key") do
          nil ->
            set_state(chat_id, "awaiting_api_key")
            setup_prompt(token, chat_id, "API KEY topilmadi. Qaytadan kiriting (15 belgi):")

          api_key ->
            if valid_api_credential?(trimmed) do
              combined = api_key <> ":" <> trimmed
              SettingsStore.upsert(%{erp_token: combined})
              # ERP URL/token changed → reset incremental sync watermarks and refresh cache
              SyncState.reset_all()
              ErpSyncWorker.sync_now(true)
              delete_setup_prompt(token, chat_id)
              clear_temp(chat_id)
              set_state(chat_id, "ready")
              upsert_session(chat_id, combined, user)
              send_message(token, chat_id, "Ulandi. /batch buyrug'ini bering.")
            else
              setup_prompt(
                token,
                chat_id,
                "API SECRET noto'g'ri (15 ta harf/raqam kerak). Qaytadan kiriting:"
              )
            end
        end

      "awaiting_weight" ->
        case parse_weight(text) do
          {:ok, weight} ->
            delete_message(token, chat_id, msg_id)

            product_id =
              get_temp(chat_id, "pending_product") || get_temp(chat_id, "batch_product")

            if product_id do
              process_print(token, chat_id, product_id, weight, true)
            else
              send_message(token, chat_id, "Mahsulot topilmadi. /batch bosing.")
            end

          :error ->
            send_message(
              token,
              chat_id,
              "Vazn noto'g'ri. Iltimos kg ko'rinishida kiriting (masalan 12.345)."
            )
        end

      _ ->
        # If scale_read failed (offline/timeout) we still want operators to be able to type
        # manual weight while staying in batch mode.
        if batch_active?(chat_id) do
          case parse_weight(text) do
            {:ok, weight} ->
              product_id =
                get_temp(chat_id, "pending_product") || get_temp(chat_id, "batch_product")

              if product_id do
                delete_message(token, chat_id, msg_id)
                process_print(token, chat_id, product_id, weight, true)
              else
                :ok
              end

            :error ->
              :ok
          end
        else
          :ok
        end
    end
  end

  defp send_batch_prompt(token, chat_id) do
    case ErpClient.ping() do
      {:ok, _} ->
        delete_flow_msg(token, chat_id)
        delete_temp(chat_id, "pending_product")
        delete_temp(chat_id, "warehouse")
        delete_temp(chat_id, "batch_active")
        set_state(chat_id, "ready")
        put_temp(chat_id, "inline_mode", "product")

        keyboard = %{
          "inline_keyboard" => [
            [%{"text" => "Mahsulot tanlash", "switch_inline_query_current_chat" => ""}]
          ]
        }

        mid =
          send_message(
            token,
            chat_id,
            "Mahsulot tanlash uchun pastdagi tugmani bosing.",
            keyboard
          )

        put_temp(chat_id, "flow_msg_id", mid)

      {:error, _reason} ->
        keyboard = %{
          "inline_keyboard" => [[%{"text" => "Qayta urinish", "callback_data" => "retry_batch"}]]
        }

        send_message(
          token,
          chat_id,
          "ERPNext bilan aloqa yo'q. Tekshirib qayta urinib ko'ring.",
          keyboard
        )
    end
  end

  defp stop_batch(token, chat_id) do
    product_id = get_temp(chat_id, "pending_product")
    clear_batch_msgs(token, chat_id)
    delete_flow_msg(token, chat_id)
    clear_temp(chat_id)
    set_state(chat_id, "ready")

    if product_id do
      send_message(
        token,
        chat_id,
        "Batch tugatildi (#{product_id}). Yangi batch uchun /batch bosing."
      )
    else
      send_message(token, chat_id, "Batch tugatildi. Yangi batch uchun /batch bosing.")
    end
  end

  defp send_warehouse_prompt(token, chat_id) do
    put_temp(chat_id, "inline_mode", "warehouse")

    keyboard = %{
      "inline_keyboard" => [
        [%{"text" => "Ombor tanlash", "switch_inline_query_current_chat" => "wh "}]
      ]
    }

    send_message(token, chat_id, "Ombor tanlang:", keyboard)
  end

  defp handle_warehouse_selection(token, chat_id, warehouse) do
    product_id = get_temp(chat_id, "pending_product")

    if is_binary(product_id) and String.trim(product_id) != "" do
      put_temp(chat_id, "warehouse", warehouse)
      put_temp(chat_id, "batch_product", product_id)
      put_temp(chat_id, "batch_active", "true")
      put_temp(chat_id, "batch_count", 0)
      put_temp(chat_id, "batch_scale_fail_count", 0)
      put_temp(chat_id, "batch_draft_fail_count", 0)
      reset_batch_cycle(chat_id)
      delete_temp(chat_id, "inline_mode")
      set_state(chat_id, "batch")

      batch_text =
        "Batch rejim: #{product_id} → #{warehouse}\n" <>
          "Mahsulot qo'yilishini kutyapman...\n" <>
          "Tugatish uchun /stop"

      flow_mid = get_temp(chat_id, "flow_msg_id")

      if flow_mid do
        edit_message(token, chat_id, flow_mid, batch_text)
      else
        mid = send_message(token, chat_id, batch_text)
        put_temp(chat_id, "flow_msg_id", mid)
      end

      begin_weight_flow(token, chat_id, product_id)
    else
      put_temp(chat_id, "warehouse", warehouse)
      delete_temp(chat_id, "inline_mode")
      put_temp(chat_id, "inline_mode", "product")

      keyboard = %{
        "inline_keyboard" => [
          [%{"text" => "Mahsulot tanlash", "switch_inline_query_current_chat" => ""}]
        ]
      }

      flow_mid = get_temp(chat_id, "flow_msg_id")

      if flow_mid do
        edit_message(
          token,
          chat_id,
          flow_mid,
          "Ombor: #{warehouse}\nEndi mahsulot tanlang:",
          keyboard
        )
      else
        mid =
          send_message(token, chat_id, "Ombor: #{warehouse}\nEndi mahsulot tanlang:", keyboard)

        put_temp(chat_id, "flow_msg_id", mid)
      end
    end
  end

  defp handle_product_selection(token, chat_id, product_id) do
    put_temp(chat_id, "pending_product", product_id)
    put_temp(chat_id, "batch_product", product_id)
    set_state(chat_id, "awaiting_warehouse")
    put_temp(chat_id, "inline_mode", "warehouse")

    item_name =
      case Cache.get_item(product_id) do
        nil -> product_id
        item -> Map.get(item, :item_name) || product_id
      end

    keyboard = %{
      "inline_keyboard" => [
        [%{"text" => "Ombor tanlash", "switch_inline_query_current_chat" => "wh "}]
      ]
    }

    flow_mid = get_temp(chat_id, "flow_msg_id")

    if flow_mid do
      edit_message(token, chat_id, flow_mid, "Mahsulot: #{item_name}\nOmbor tanlang:", keyboard)
    else
      mid = send_message(token, chat_id, "Mahsulot: #{item_name}\nOmbor tanlang:", keyboard)
      put_temp(chat_id, "flow_msg_id", mid)
    end
  end

  defp begin_weight_flow(token, chat_id, product_id) do
    mark_batch_loop_heartbeat(chat_id)
    # Draft is created in ERPNext as "Material Issue". We intentionally don't hard-block on
    # local stock cache here (it can be stale); ERP will validate on draft creation.
    do_weight_flow(token, chat_id, product_id)
  end

  defp do_weight_flow(token, chat_id, product_id) do
    # Always try real scale first; transient failures are auto-retried.
    case core_command(chat_id, "scale_read", %{}, batch_scale_timeout_ms()) do
      {:ok, %{"weight" => weight} = payload} when is_number(weight) ->
        stable = payload["stable"]
        maybe_process_scale_read(token, chat_id, product_id, weight, stable, payload)

      {:ok, %{weight: weight} = payload} when is_number(weight) ->
        stable = Map.get(payload, :stable)
        maybe_process_scale_read(token, chat_id, product_id, weight, stable, payload)

      {:ok, _} ->
        handle_scale_read_failure(token, chat_id, product_id, :invalid_payload)

      {:error, reason} ->
        handle_scale_read_failure(token, chat_id, product_id, reason)
    end
  end

  defp maybe_process_scale_read(token, chat_id, product_id, weight, stable, payload) do
    min_weight = max(batch_min_weight(), 0.001)
    zero_threshold = min(batch_zero_threshold(), min_weight)
    poll_ms = batch_poll_ms()

    put_temp(chat_id, "batch_scale_fail_count", 0)

    case batch_cycle_state(chat_id) do
      :wait_reset ->
        min_observed_weight = update_wait_reset_min_weight(chat_id, weight)
        observed_zero? = weight <= zero_threshold
        near_zero_threshold = batch_reset_near_zero_threshold(min_weight, zero_threshold)
        observed_near_zero? = min_observed_weight <= near_zero_threshold
        rearm_delta = batch_rearm_delta()
        weight_changed? = moved_from_last_print?(chat_id, weight, rearm_delta)

        # Re-arm on: (a) near-zero reset, OR (b) significant weight change.
        # This allows continuous weighing — no need to remove product from scale.
        should_rearm? = observed_zero? or observed_near_zero? or weight_changed?

        if should_rearm? do
          Logger.debug(
            "[batch] rearm chat=#{chat_id} w=#{weight} zero=#{observed_zero?} " <>
              "min_observed=#{min_observed_weight} near_zero=#{observed_near_zero?} " <>
              "weight_changed=#{weight_changed?}"
          )

          set_batch_cycle_state(chat_id, :wait_item)
          clear_wait_reset_min_weight(chat_id)
          clear_batch_candidate(chat_id)
          process_wait_item_state(token, chat_id, product_id, weight, stable, payload)
        else
          schedule_batch_next(token, chat_id, product_id, poll_ms)
        end

      :wait_item ->
        process_wait_item_state(token, chat_id, product_id, weight, stable, payload)
    end
  end

  defp process_wait_item_state(token, chat_id, product_id, weight, stable, _payload) do
    min_weight = max(batch_min_weight(), 0.001)
    stable_window_ms = batch_stable_window_ms()
    stable_epsilon = batch_stable_epsilon()
    require_stable = batch_require_stable?()
    force_print = batch_force_print_on_weight?()
    poll_ms = batch_poll_ms()
    unstable = stable_false?(stable)
    now_ms = System.monotonic_time(:millisecond)

    cond do
      weight <= min_weight ->
        clear_batch_candidate(chat_id)
        delete_temp(chat_id, "batch_force_last_attempt_ms")
        schedule_batch_next(token, chat_id, product_id, poll_ms)

      force_print and force_print_allowed_now?(chat_id) ->
        clear_batch_candidate(chat_id)
        process_print(token, chat_id, product_id, weight, false)

      require_stable and unstable ->
        clear_batch_candidate(chat_id)
        schedule_batch_next(token, chat_id, product_id, poll_ms)

      true ->
        case batch_candidate(chat_id) do
          {:ok, candidate_weight, candidate_since_ms}
          when abs(weight - candidate_weight) <= stable_epsilon ->
            if now_ms - candidate_since_ms >= stable_window_ms do
              process_print(token, chat_id, product_id, weight, false)
            else
              schedule_batch_next(token, chat_id, product_id, poll_ms)
            end

          _ ->
            set_batch_candidate(chat_id, weight)
            schedule_batch_next(token, chat_id, product_id, poll_ms)
        end
    end
  end

  defp prompt_manual_weight(token, chat_id, product_id) do
    put_temp(chat_id, "pending_product", product_id)
    put_temp(chat_id, "batch_product", product_id)
    set_state(chat_id, "awaiting_weight")

    track_batch_msg(
      chat_id,
      send_message(token, chat_id, "Tarozi topilmadi. Vaznni kiriting (masalan 12.345):")
    )
  end

  defp handle_scale_read_failure(token, chat_id, product_id, reason) do
    poll_ms = batch_poll_ms()
    retries = batch_scale_fail_retries()
    manual_fallback = batch_manual_fallback?()
    fail_count = (get_temp(chat_id, "batch_scale_fail_count") || 0) + 1
    put_temp(chat_id, "batch_scale_fail_count", fail_count)

    if fail_count == 1 and not manual_fallback do
      flow_mid = get_temp(chat_id, "flow_msg_id")
      text = "Tarozi bilan aloqa uzildi. Avtomatik qayta ulanmoqda..."

      if is_integer(flow_mid) do
        Task.start(fn -> edit_message(token, chat_id, flow_mid, text) end)
      end
    end

    if rem(fail_count, 10) == 1 do
      Logger.warning(
        "scale_read failed ##{fail_count}: #{inspect(reason)} (manual_fallback=#{manual_fallback})"
      )
    end

    cond do
      manual_fallback and fail_count >= retries ->
        Logger.warning("scale_read failed #{fail_count} times; switching to manual weight input")
        prompt_manual_weight(token, chat_id, product_id)

      true ->
        schedule_batch_next(token, chat_id, product_id, poll_ms)
    end
  end

  defp process_print(token, chat_id, product_id, weight, manual?) do
    min_weight = max(batch_min_weight(), 0.001)

    if weight <= min_weight do
      Logger.warning("[tg] skip print: invalid weight=#{weight} (min=#{min_weight})")
      maybe_continue_batch(token, chat_id, product_id, "Vazn juda kichik: #{weight} kg")
    else
      Logger.info(
        "[tg] print flow: chat_id=#{chat_id} product_id=#{product_id} weight=#{weight} manual=#{manual?}"
      )

      flow_mid = get_temp(chat_id, "flow_msg_id")

      # Telegram API sekin bo'lsa ham print sikli ushlanmasin.
      processing_text =
        "Ishlov berilyapti...\n" <>
          "Mahsulot: #{product_id}\n" <>
          "Vazn: #{weight} kg"

      if is_integer(flow_mid) do
        Task.start(fn -> edit_message(token, chat_id, flow_mid, processing_text) end)
      end

      t0 = System.monotonic_time(:millisecond)

      case print_label_with_epc_retry(chat_id, product_id, weight, t0) do
        {epc, print_result} ->
          print_ok = match?({:ok, _}, print_result)
          Logger.info("[tg] print_label ok=#{print_ok} dt=#{ms_since(t0)}ms")

          print_error =
            case print_result do
              {:error, reason} -> reason_text(reason)
              _ -> nil
            end

          if not print_ok do
            Logger.warning("[tg] print_label failed: #{print_error}")
          end

          rfid_enabled = ChildrenTarget.enabled?("rfid")

          rfid_result =
            cond do
              not rfid_enabled ->
                {:ok, %{"skipped" => true}}

              print_ok ->
                core_command(chat_id, "rfid_write", %{"epc" => epc}, batch_rfid_timeout_ms())

              true ->
                {:error, "printer not ready"}
            end

          rfid_ok = match?({:ok, _}, rfid_result)
          Logger.info("[tg] rfid_write ok=#{rfid_ok} dt=#{ms_since(t0)}ms")

          rfid_error =
            case rfid_result do
              {:error, reason} -> reason_text(reason)
              _ -> nil
            end

          warehouse = get_chat_warehouse(chat_id) || get_setting(:warehouse)
          draft_attempted = print_ok
          batch_mode = batch_active?(chat_id)

          draft_result =
            cond do
              not draft_attempted ->
                {:error, "printer failed"}

              batch_mode ->
                start_draft_async(chat_id, product_id, warehouse, weight, epc)
                :queued

              true ->
                create_draft_sync(product_id, warehouse, weight, epc, t0)
            end

          Task.start(fn ->
            ErpClient.create_log(%{
              "device_id" => device_id(chat_id),
              "action" => "print_label",
              "status" => if(print_ok, do: "Success", else: "Error"),
              "product_id" => product_id,
              "message" => (print_ok && "Printed EPC #{epc}") || "Print skipped: #{print_error}"
            })
          end)

          draft_label =
            case draft_result do
              :ok -> "Draft OK"
              :queued -> "Draft yuborildi"
              {:error, reason} -> "Draft xato: " <> ErpClient.human_error(reason)
            end

          result_text =
            cond do
              not print_ok ->
                "Printer xato: #{print_error}"

              not rfid_enabled ->
                "#{weight} kg | #{draft_label}"

              rfid_ok ->
                "#{weight} kg | #{draft_label}"

              true ->
                "#{weight} kg | #{draft_label} | RFID xato: #{rfid_error}"
            end

          if batch_active?(chat_id) do
            if print_ok do
              # Printed successfully: wait for item removal (scale -> near zero), then re-arm.
              set_batch_cycle_state(chat_id, :wait_reset)
              set_last_printed_weight(chat_id, weight)
              clear_batch_candidate(chat_id)
            else
              # Print failed: stay in wait_item and restart 1s stability window for retry.
              set_batch_cycle_state(chat_id, :wait_item)
              set_batch_candidate(chat_id, weight)
            end
          end

          if not batch_mode and draft_attempted and match?({:error, _}, draft_result) do
            {:error, reason} = draft_result

            if is_integer(flow_mid) do
              edit_message(
                token,
                chat_id,
                flow_mid,
                "Draft xato: #{ErpClient.human_error(reason)}"
              )
            else
              send_message(
                token,
                chat_id,
                "Draft xato: #{ErpClient.human_error(reason)}"
              )
            end
          else
            if print_ok do
              increment_batch_count(chat_id)
              count = get_temp(chat_id, "batch_count") || 0
              item_text = "🖨 #{count}-chi item print qilindi\n#{result_text}"
              Task.start(fn -> send_message(token, chat_id, item_text) end)
            end

            maybe_continue_batch(token, chat_id, product_id, result_text)
          end
      end
    end
  end

  defp maybe_continue_batch(token, chat_id, product_id, result_text) do
    if ensure_batch_loop_active?(chat_id, product_id) do
      warehouse = get_temp(chat_id, "warehouse") || "-"
      count = get_temp(chat_id, "batch_count") || 0

      text =
        "✓ #{result_text}\n" <>
          "Batch: #{product_id} → #{warehouse} (#{count} ta)\n" <>
          "Kutyapman...\nTugatish uchun /stop"

      schedule_batch_next(token, chat_id, product_id)

      flow_mid = get_temp(chat_id, "flow_msg_id")

      Task.start(fn ->
        if flow_mid do
          edit_message(token, chat_id, flow_mid, text)
        else
          mid = send_message(token, chat_id, text)
          if is_integer(mid), do: put_temp(chat_id, "flow_msg_id", mid)
        end
      end)
    end
  end

  defp batch_active?(chat_id) do
    case get_temp(chat_id, "batch_active") do
      true -> true
      1 -> true
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      _ -> false
    end
  end

  defp ensure_batch_loop_active?(chat_id, product_id) do
    if batch_active?(chat_id) do
      true
    else
      state = get_state(chat_id)
      temp_product = get_temp(chat_id, "batch_product") || get_temp(chat_id, "pending_product")

      active_product =
        cond do
          is_binary(temp_product) and String.trim(temp_product) != "" -> temp_product
          is_binary(product_id) and String.trim(product_id) != "" -> product_id
          true -> nil
        end

      recoverable? =
        state in ["batch", "awaiting_weight"] and
          is_binary(active_product) and String.trim(active_product) != ""

      if recoverable? do
        put_temp(chat_id, "batch_active", "true")
        put_temp(chat_id, "batch_product", active_product)
        put_temp(chat_id, "pending_product", active_product)
      end

      recoverable?
    end
  end

  defp schedule_batch_next(token, chat_id, product_id, delay_ms \\ nil) do
    ms = delay_ms || batch_poll_ms()
    Process.send_after(self(), {:batch_next, token, chat_id, product_id}, ms)
  end

  defp schedule_batch_watchdog(ms) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :batch_watchdog, ms)
  end

  defp recover_stalled_batch_loops do
    token = telegram_token()

    if is_binary(token) and token != "" do
      now_ms = System.monotonic_time(:millisecond)
      stale_after_ms = batch_watchdog_stale_ms()

      active_batch_chat_ids()
      |> Enum.each(fn chat_id ->
        product_id = get_temp(chat_id, "batch_product") || get_temp(chat_id, "pending_product")
        last_loop_ms = parse_int_temp(get_temp(chat_id, "batch_last_loop_ms")) || 0

        cond do
          not batch_active?(chat_id) ->
            :ok

          not (is_binary(product_id) and String.trim(product_id) != "") ->
            :ok

          now_ms - last_loop_ms < stale_after_ms ->
            :ok

          true ->
            Logger.warning(
              "[batch] watchdog recovered stalled loop " <>
                "chat=#{chat_id} product=#{product_id} stale_ms=#{now_ms - last_loop_ms}"
            )

            put_temp(chat_id, "batch_active", "true")
            put_temp(chat_id, "batch_product", product_id)
            put_temp(chat_id, "pending_product", product_id)
            set_state(chat_id, "batch")
            put_temp(chat_id, "batch_last_loop_ms", now_ms)
            schedule_batch_next(token, chat_id, product_id, 0)
        end
      end)
    end
  end

  defp mark_batch_loop_heartbeat(chat_id) do
    put_temp(chat_id, "batch_last_loop_ms", System.monotonic_time(:millisecond))
  end

  defp active_batch_chat_ids do
    @temp_table
    |> :ets.tab2list()
    |> Enum.reduce(MapSet.new(), fn
      {{chat_id, "batch_active"}, value}, acc ->
        if batch_active_value?(value), do: MapSet.put(acc, chat_id), else: acc

      _, acc ->
        acc
    end)
    |> MapSet.to_list()
  end

  defp batch_active_value?(value) do
    value in [true, 1, "1", "true", "yes", "on"]
  end

  defp start_draft_async(chat_id, product_id, warehouse, weight, epc) do
    Task.start(fn ->
      t0 = System.monotonic_time(:millisecond)
      result = create_draft_sync(product_id, warehouse, weight, epc, t0)
      send(__MODULE__, {:batch_draft_result, chat_id, product_id, weight, epc, result})
    end)
  end

  defp create_draft_sync(product_id, warehouse, weight, epc, t0) do
    Logger.info("[tg] erp create_draft starting dt=#{ms_since(t0)}ms")

    case ErpClient.create_draft(%{
           "product_id" => product_id,
           "warehouse" => warehouse,
           "weight_kg" => weight,
           "epc_code" => epc
         }) do
      {:ok, data} ->
        Logger.info("Stock Entry draft created: #{inspect(data["data"]["name"])}")
        Logger.info("[tg] erp create_draft ok dt=#{ms_since(t0)}ms")
        :ok

      {:error, reason} ->
        Logger.warning("Stock Entry draft FAILED: #{inspect(reason)}")
        Logger.info("[tg] erp create_draft error dt=#{ms_since(t0)}ms")
        {:error, reason}
    end
  end

  defp batch_poll_ms do
    default = Application.get_env(:titan_bridge, __MODULE__)[:batch_poll_ms] || 20
    parse_int_env("LCE_BATCH_POLL_MS", default)
  end

  defp batch_watchdog_interval_ms do
    parse_int_env("LCE_BATCH_WATCHDOG_INTERVAL_MS", 500)
  end

  defp batch_watchdog_stale_ms do
    parse_int_env("LCE_BATCH_WATCHDOG_STALE_MS", 2500)
  end

  defp batch_scale_timeout_ms do
    parse_int_env("LCE_BATCH_SCALE_TIMEOUT_MS", 700)
  end

  defp batch_print_timeout_ms do
    parse_int_env("LCE_BATCH_PRINT_TIMEOUT_MS", 1800)
  end

  defp batch_rfid_timeout_ms do
    parse_int_env("LCE_BATCH_RFID_TIMEOUT_MS", 1200)
  end

  defp batch_min_weight do
    parse_float_env("LCE_BATCH_MIN_WEIGHT", 0.1)
  end

  defp batch_zero_threshold do
    parse_float_env("LCE_BATCH_ZERO_THRESHOLD", 0.02)
  end

  defp batch_scale_fail_retries do
    parse_int_env("LCE_BATCH_SCALE_FAIL_RETRIES", 90)
  end

  defp batch_manual_fallback? do
    parse_bool_env("LCE_BATCH_MANUAL_FALLBACK", false)
  end

  defp batch_force_print_on_weight? do
    parse_bool_env("LCE_BATCH_FORCE_PRINT_ON_WEIGHT", false)
  end

  defp batch_force_min_interval_ms do
    parse_int_env("LCE_BATCH_FORCE_MIN_INTERVAL_MS", 300)
  end

  defp batch_require_stable? do
    parse_bool_env("LCE_BATCH_REQUIRE_STABLE", true)
  end

  defp batch_stable_window_ms do
    parse_int_env("LCE_BATCH_STABLE_WINDOW_MS", 1000)
  end

  defp batch_stable_epsilon do
    parse_float_env("LCE_BATCH_STABLE_EPSILON", 0.03)
  end

  defp batch_rearm_delta do
    parse_float_env("LCE_BATCH_REARM_DELTA", 0.03)
  end

  defp batch_reset_near_zero_threshold(min_weight, zero_threshold)
       when is_number(min_weight) and is_number(zero_threshold) do
    configured = parse_float_env("LCE_BATCH_RESET_NEAR_ZERO_THRESHOLD", 0.20)
    max(configured, max(zero_threshold, min_weight))
  end

  defp reset_batch_cycle(chat_id) do
    set_batch_cycle_state(chat_id, :wait_item)
    clear_batch_candidate(chat_id)
    clear_last_printed_weight(chat_id)
    clear_wait_reset_min_weight(chat_id)
  end

  defp batch_cycle_state(chat_id) do
    case get_temp(chat_id, "batch_cycle_state") do
      "wait_reset" -> :wait_reset
      _ -> :wait_item
    end
  end

  defp set_batch_cycle_state(chat_id, :wait_item),
    do: put_temp(chat_id, "batch_cycle_state", "wait_item")

  defp set_batch_cycle_state(chat_id, :wait_reset),
    do: put_temp(chat_id, "batch_cycle_state", "wait_reset")

  defp batch_candidate(chat_id) do
    with raw_weight when not is_nil(raw_weight) <- get_temp(chat_id, "batch_candidate_weight"),
         {weight, _} when is_number(weight) <- Float.parse(to_string(raw_weight)),
         since_ms when is_integer(since_ms) <-
           parse_int_temp(get_temp(chat_id, "batch_candidate_since")) do
      {:ok, weight, since_ms}
    else
      _ -> :none
    end
  end

  defp set_batch_candidate(chat_id, weight) when is_number(weight) do
    put_temp(
      chat_id,
      "batch_candidate_weight",
      :erlang.float_to_binary(weight * 1.0, decimals: 6)
    )

    put_temp(chat_id, "batch_candidate_since", System.monotonic_time(:millisecond))
  end

  defp clear_batch_candidate(chat_id) do
    delete_temp(chat_id, "batch_candidate_weight")
    delete_temp(chat_id, "batch_candidate_since")
  end

  defp moved_from_last_print?(chat_id, weight, rearm_delta) when is_number(weight) do
    case last_printed_weight(chat_id) do
      prev_weight when is_number(prev_weight) ->
        # Dynamic threshold: max(fixed_delta, 6% of last weight).
        # This prevents false rearms from scale noise while allowing
        # real weight changes to be detected.
        # Examples: 9kg→threshold=0.54, 2kg→0.12, 0.5kg→0.03
        threshold = max(rearm_delta, prev_weight * 0.06)
        abs(weight - prev_weight) >= threshold

      _ ->
        false
    end
  end

  defp observed_drop_from_last?(chat_id, weight, min_observed_weight, zero_threshold, rearm_delta) do
    case last_printed_weight(chat_id) do
      prev_weight when is_number(prev_weight) ->
        drop_floor = max(zero_threshold, prev_weight - rearm_delta)

        weight <= drop_floor or
          (is_number(min_observed_weight) and min_observed_weight <= drop_floor)

      _ ->
        false
    end
  end

  defp last_printed_weight(chat_id) do
    case get_temp(chat_id, "batch_last_printed_weight") do
      nil ->
        nil

      raw ->
        case Float.parse(to_string(raw)) do
          {prev_weight, _} when is_number(prev_weight) ->
            prev_weight

          _ ->
            nil
        end
    end
  end

  defp set_last_printed_weight(chat_id, weight) when is_number(weight) do
    put_temp(
      chat_id,
      "batch_last_printed_weight",
      :erlang.float_to_binary(weight * 1.0, decimals: 6)
    )
  end

  defp clear_last_printed_weight(chat_id) do
    delete_temp(chat_id, "batch_last_printed_weight")
  end

  defp update_wait_reset_min_weight(chat_id, weight) when is_number(weight) do
    prev =
      case get_temp(chat_id, "batch_wait_reset_min_weight") do
        nil ->
          nil

        raw ->
          case Float.parse(to_string(raw)) do
            {v, _} when is_number(v) -> v
            _ -> nil
          end
      end

    next =
      case prev do
        nil -> weight
        v when is_number(v) -> min(v, weight)
      end

    put_temp(
      chat_id,
      "batch_wait_reset_min_weight",
      :erlang.float_to_binary(next * 1.0, decimals: 6)
    )

    next
  end

  defp clear_wait_reset_min_weight(chat_id) do
    delete_temp(chat_id, "batch_wait_reset_min_weight")
  end

  defp force_print_allowed_now?(chat_id) do
    now_ms = System.monotonic_time(:millisecond)
    min_interval = batch_force_min_interval_ms()

    case parse_int_temp(get_temp(chat_id, "batch_force_last_attempt_ms")) do
      nil ->
        put_temp(chat_id, "batch_force_last_attempt_ms", now_ms)
        true

      last_ms when is_integer(last_ms) and now_ms - last_ms >= min_interval ->
        put_temp(chat_id, "batch_force_last_attempt_ms", now_ms)
        true

      _ ->
        false
    end
  end

  defp parse_int_temp(value) do
    case value do
      v when is_integer(v) ->
        v

      v when is_float(v) ->
        trunc(v)

      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {parsed, _} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp stable_false?(stable) do
    case stable do
      false -> true
      "false" -> true
      "0" -> true
      0 -> true
      _ -> false
    end
  end

  defp parse_float_env(key, default) when is_binary(key) and is_number(default) do
    case System.get_env(key) do
      nil ->
        default

      raw ->
        case Float.parse(String.trim(raw)) do
          {value, ""} when is_number(value) -> value
          _ -> default
        end
    end
  end

  defp parse_int_env(key, default) when is_binary(key) and is_integer(default) do
    case System.get_env(key) do
      nil ->
        default

      raw ->
        case Integer.parse(String.trim(raw)) do
          {value, ""} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp parse_bool_env(key, default) when is_binary(key) and is_boolean(default) do
    case System.get_env(key) do
      nil ->
        default

      raw ->
        case String.trim(raw) |> String.downcase() do
          "1" -> true
          "true" -> true
          "yes" -> true
          "y" -> true
          "on" -> true
          "0" -> false
          "false" -> false
          "no" -> false
          "n" -> false
          "off" -> false
          _ -> default
        end
    end
  end

  defp next_epc_checked(retries \\ 5)
  defp next_epc_checked(0), do: {:error, "EPC conflict"}

  defp next_epc_checked(retries) when retries > 0 do
    with {:ok, epc} <- EpcGenerator.next() do
      if epc_conflict_check_enabled?() do
        case ErpClient.epc_exists?(epc) do
          {:ok, _} -> next_epc_checked(retries - 1)
          :not_found -> {:ok, epc}
          {:error, _} -> {:ok, epc}
        end
      else
        {:ok, epc}
      end
    end
  end

  defp epc_conflict_check_enabled? do
    parse_bool_env("LCE_EPC_CONFLICT_CHECK", false)
  end

  defp print_label_with_epc_retry(chat_id, product_id, weight, t0) do
    do_print_label_with_epc_retry(chat_id, product_id, weight, t0, batch_print_epc_retries())
  end

  defp do_print_label_with_epc_retry(chat_id, product_id, weight, t0, retries_left)
       when retries_left > 0 do
    case next_epc_checked() do
      {:ok, epc} ->
        Logger.info("[tg] epc reserved epc=#{epc} dt=#{ms_since(t0)}ms")

        print_payload = %{
          "epc" => epc,
          "product_id" => product_id,
          "weight_kg" => weight,
          "label_fields" => %{
            "product_name" => product_id,
            "weight_kg" => to_string(weight),
            "epc_hex" => epc
          }
        }

        print_result =
          core_command(chat_id, "print_label", print_payload, batch_print_timeout_ms())

        case print_result do
          {:ok, _} ->
            {epc, print_result}

          {:error, reason} ->
            error_text = reason_text(reason)

            if epc_conflict_error?(error_text) and retries_left > 1 do
              Logger.warning(
                "[tg] print_label epc_conflict, retry with new epc " <>
                  "(left=#{retries_left - 1})"
              )

              do_print_label_with_epc_retry(chat_id, product_id, weight, t0, retries_left - 1)
            else
              {epc, print_result}
            end
        end

      {:error, reason} ->
        {nil, {:error, reason}}
    end
  end

  defp do_print_label_with_epc_retry(_chat_id, _product_id, _weight, _t0, _retries_left) do
    {nil, {:error, "print retry exhausted"}}
  end

  defp batch_print_epc_retries do
    parse_int_env("LCE_BATCH_PRINT_EPC_RETRIES", 5)
  end

  defp epc_conflict_error?(error_text) when is_binary(error_text) do
    normalized = String.downcase(error_text)
    String.contains?(normalized, "epc_conflict") or String.contains?(normalized, "epc conflict")
  end

  defp epc_conflict_error?(_), do: false

  defp parse_weight(text) do
    sanitized = String.replace(text || "", ",", ".") |> String.trim()

    case Float.parse(sanitized) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp friendly_error(reason) do
    text = reason_text(reason || "")

    cond do
      String.contains?(text, "offline") ->
        "Xato: Core agent offline. Qurilma ishlayotganini tekshiring."

      String.contains?(text, "timeout") ->
        "Xato: Core javob bermadi (timeout)."

      true ->
        "Xato: #{text}"
    end
  end

  defp reason_text(reason) do
    cond do
      is_binary(reason) ->
        reason

      is_atom(reason) ->
        Atom.to_string(reason)

      is_map(reason) and is_binary(reason["error"]) ->
        reason["error"]

      is_map(reason) and is_binary(reason[:error]) ->
        reason[:error]

      true ->
        inspect(reason)
    end
  end

  defp device_id(chat_id \\ nil) do
    get_setting(:device_id) || (chat_id && "LCE-#{chat_id}") || "LCE-DEVICE"
  end

  defp core_command(chat_id, name, payload, timeout_ms) do
    target = core_device_id(chat_id)
    t0 = System.monotonic_time(:millisecond)

    result =
      try do
        CoreHub.command(target, name, payload, timeout_ms)
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    dt = System.monotonic_time(:millisecond) - t0
    Logger.debug("[tg] core_command name=#{name} dt=#{dt}ms ok=#{match?({:ok, _}, result)}")
    result
  end

  defp core_device_id(_chat_id) do
    get_setting(:device_id)
  end

  defp ms_since(t0_ms) when is_integer(t0_ms) do
    System.monotonic_time(:millisecond) - t0_ms
  end

  defp upsert_session(chat_id, token, user) do
    device = device_id(chat_id)
    erp_url = get_setting(:erp_url)
    user_id = user["id"]
    username = user["username"]

    ErpClient.upsert_device(%{
      "device_id" => device,
      "chat_id" => to_string(chat_id),
      "user_id" => to_string(user_id || ""),
      "status" => "Online"
    })

    ErpClient.upsert_session(%{
      "chat_id" => to_string(chat_id),
      "user_id" => to_string(user_id || ""),
      "username" => to_string(username || ""),
      "device_id" => device,
      "erp_url" => erp_url,
      "api_token" => token,
      "status" => "Active"
    })
  end

  defp get_setting(field) do
    case SettingsStore.get() do
      nil -> nil
      settings -> Map.get(settings, field)
    end
  end

  defp telegram_token do
    case SettingsStore.get() do
      %{telegram_token: token} when is_binary(token) and byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp get_products_cache(chat_id) do
    now = System.system_time(:millisecond)

    case ChatState.get_temp(@temp_table, chat_id, :products) do
      {ts, products} when now - ts < @products_cache_ttl_ms ->
        {:ok, products}

      _ ->
        :miss
    end
  end

  defp get_warehouses_cache(chat_id) do
    now = System.system_time(:millisecond)

    case ChatState.get_temp(@temp_table, chat_id, :warehouses) do
      {ts, warehouses} when now - ts < @warehouses_cache_ttl_ms ->
        {:ok, warehouses}

      _ ->
        :miss
    end
  end

  defp put_products_cache(chat_id, products) do
    ChatState.put_temp(
      @temp_table,
      chat_id,
      :products,
      {System.system_time(:millisecond), products}
    )
  end

  defp put_warehouses_cache(chat_id, warehouses) when is_list(warehouses) do
    ChatState.put_temp(
      @temp_table,
      chat_id,
      :warehouses,
      {System.system_time(:millisecond), warehouses}
    )
  end

  defp get_chat_warehouse(chat_id) do
    get_temp(chat_id, "warehouse")
  end

  defp setup_prompt(token, chat_id, text) do
    old_mid = get_temp(chat_id, "setup_msg_id")
    if old_mid, do: delete_message(token, chat_id, old_mid)
    new_mid = send_message(token, chat_id, text)
    put_temp(chat_id, "setup_msg_id", new_mid)
  end

  defp delete_flow_msg(token, chat_id) do
    old_mid = get_temp(chat_id, "flow_msg_id")
    if old_mid, do: delete_message(token, chat_id, old_mid)
    delete_temp(chat_id, "flow_msg_id")
  end

  defp increment_batch_count(chat_id) do
    old = get_temp(chat_id, "batch_count") || 0
    put_temp(chat_id, "batch_count", old + 1)
  end

  defp track_batch_msg(chat_id, mid) when is_integer(mid) do
    old = get_temp(chat_id, "batch_msgs") || []
    put_temp(chat_id, "batch_msgs", [mid | old])
  end

  defp track_batch_msg(_, _), do: :ok

  defp clear_batch_msgs(token, chat_id) do
    msgs = get_temp(chat_id, "batch_msgs") || []
    Enum.each(msgs, fn mid -> delete_message(token, chat_id, mid) end)
    delete_temp(chat_id, "batch_msgs")
  end

  defp delete_setup_prompt(token, chat_id) do
    old_mid = get_temp(chat_id, "setup_msg_id")
    if old_mid, do: delete_message(token, chat_id, old_mid)
    delete_temp(chat_id, "setup_msg_id")
  end

  defp valid_api_credential?(value), do: SetupUtils.valid_api_credential?(value)

  defp normalize_erp_url(url), do: SetupUtils.normalize_erp_url(url)

  defp put_temp(chat_id, key, value) do
    ChatState.put_temp(@temp_table, chat_id, key, value)
  end

  defp get_temp(chat_id, key) do
    ChatState.get_temp(@temp_table, chat_id, key)
  end

  defp delete_temp(chat_id, key) do
    ChatState.delete_temp(@temp_table, chat_id, key)
  end

  defp clear_temp(chat_id) do
    ChatState.clear_temp(@temp_table, chat_id)
  end

  defp send_message(token, chat_id, text, reply_markup \\ nil) do
    Transport.send_message(token, chat_id, text, reply_markup, log_level: :warning)
  end

  defp edit_message(token, chat_id, message_id, text, reply_markup \\ nil) do
    Transport.edit_message(token, chat_id, message_id, text, reply_markup, log_level: :warning)
  end

  defp answer_callback(token, callback_id, text \\ nil) do
    Transport.answer_callback(token, callback_id, text, log_level: :warning)
  end

  defp answer_inline_query(token, query_id, query_text, chat_id) do
    query = String.downcase(query_text || "")

    inline_mode = get_temp(chat_id, "inline_mode")
    awaiting_warehouse = get_state(chat_id) == "awaiting_warehouse"
    is_wh_query = String.starts_with?(query, "wh") or String.starts_with?(query, "ombor")

    {mode, q} =
      if inline_mode == "warehouse" or awaiting_warehouse or is_wh_query do
        cleaned = query |> String.replace_prefix("wh", "") |> String.replace_prefix("ombor", "")
        {"warehouse", String.trim(cleaned)}
      else
        {"product", query}
      end

    {mode, q} =
      if inline_mode == "product" do
        {"product", query}
      else
        {mode, q}
      end

    results =
      case mode do
        "warehouse" ->
          product_id = get_temp(chat_id, "pending_product")

          {warehouses, qty_map} =
            if is_binary(product_id) and String.trim(product_id) != "" do
              {qmap, qty_unknown?} =
                case Cache.qty_map_for_item(product_id) do
                  {:ok, m} -> {m, false}
                  :no_cache -> {%{}, true}
                end

              whs =
                Cache.list_warehouses()
                |> Enum.filter(fn row -> not row.disabled and not row.is_group end)

              whs =
                if length(whs) >= 2 do
                  whs
                else
                  case get_warehouses_cache(chat_id) do
                    {:ok, cached} when is_list(cached) and cached != [] ->
                      cached

                    _ ->
                      case ErpClient.list_warehouses() do
                        {:ok, rows} when is_list(rows) ->
                          put_warehouses_cache(chat_id, rows)
                          rows

                        _ ->
                          whs
                      end
                  end
                end

              {whs, Map.put(qmap, :__qty_unknown__, qty_unknown?)}
            else
              {[], %{}}
            end

          uom =
            if is_binary(product_id) do
              case Cache.get_item(product_id) do
                nil -> nil
                item -> Map.get(item, :stock_uom)
              end
            end

          qty_unknown? = Map.get(qty_map, :__qty_unknown__, false)

          warehouses
          |> Enum.sort_by(fn row ->
            code = Map.get(row, :name) || Map.get(row, "name") || ""
            qty = Map.get(qty_map, code, 0) || 0

            title =
              to_string(
                Map.get(row, :warehouse_name) || Map.get(row, "warehouse_name") ||
                  Map.get(row, :name) || Map.get(row, "name") || ""
              )

            {-qty, String.downcase(title)}
          end)
          |> Enum.filter(fn row ->
            name =
              String.downcase(
                to_string(Map.get(row, :warehouse_name) || Map.get(row, "warehouse_name") || "")
              )

            code = String.downcase(to_string(Map.get(row, :name) || Map.get(row, "name") || ""))
            q == "" or String.contains?(name, q) or String.contains?(code, q)
          end)
          |> Enum.take(50)
          |> Enum.with_index()
          |> Enum.map(fn {row, idx} ->
            title =
              Map.get(row, :warehouse_name) || Map.get(row, "warehouse_name") ||
                Map.get(row, :name) || Map.get(row, "name")

            code = Map.get(row, :name) || Map.get(row, "name") || ""
            qty = Map.get(qty_map, code, 0)

            qty_str =
              cond do
                qty_unknown? ->
                  "?"

                is_float(qty) ->
                  :erlang.float_to_binary(qty, decimals: 2)

                true ->
                  to_string(qty)
              end

            unit = uom || "dona"
            desc = "#{qty_str} #{unit}"

            %{
              "type" => "article",
              "id" => "wh-#{idx}-#{code}",
              "title" => title,
              "description" => desc,
              "input_message_content" => %{
                "message_text" => "warehouse:" <> code
              }
            }
          end)

        _ ->
          products = Cache.search_items(q, 50)

          products =
            if products == [] do
              case ErpClient.list_products(nil) do
                {:ok, items} -> items
                _ -> []
              end
            else
              products
            end

          products
          |> Enum.filter(fn item ->
            if q == "" do
              true
            else
              name =
                String.downcase(
                  to_string(Map.get(item, :item_name) || Map.get(item, "item_name") || "")
                )

              code =
                String.downcase(to_string(Map.get(item, :name) || Map.get(item, "name") || ""))

              String.contains?(name, q) or String.contains?(code, q)
            end
          end)
          |> Enum.take(50)
          |> Enum.with_index()
          |> Enum.map(fn {item, idx} ->
            title =
              Map.get(item, :item_name) || Map.get(item, "item_name") || Map.get(item, :name) ||
                Map.get(item, "name")

            code = Map.get(item, :name) || Map.get(item, "name") || ""

            %{
              "type" => "article",
              "id" => "#{idx}-#{code}",
              "title" => title,
              "description" => code,
              "input_message_content" => %{
                "message_text" => "product:" <> code
              }
            }
          end)
      end

    Transport.answer_inline_query(token, query_id, results, log_level: :warning)
  end

  defp delete_message(token, chat_id, msg_id) do
    Transport.delete_message(token, chat_id, msg_id, log_level: :warning)
  end

  defp set_state(chat_id, state) do
    ChatState.set_state(@state_table, chat_id, state)
  end

  defp get_state(chat_id) do
    ChatState.get_state(@state_table, chat_id, "none")
  end

  defp get_offset do
    ChatState.get_offset(@temp_table, 0)
  end

  defp set_offset(%{"update_id" => id}) do
    ChatState.set_offset(@temp_table, %{"update_id" => id})
  end

  defp set_offset(_), do: ChatState.set_offset(@temp_table, nil)
end
