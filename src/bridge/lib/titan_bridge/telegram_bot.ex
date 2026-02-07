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

  alias TitanBridge.{Cache, CoreHub, SettingsStore, ErpClient, EpcGenerator}

  @state_table :tg_state
  @temp_table :tg_temp
  @products_cache_ttl_ms 60_000

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @impl true
  def init(state) do
    :ets.new(@state_table, [:named_table, :set, :public])
    :ets.new(@temp_table, [:named_table, :set, :public])
    schedule_poll(0)
    {:ok, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    schedule_poll(0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:batch_next, token, chat_id, product_id}, state) do
    if get_temp(chat_id, "batch_active") == "true" do
      begin_weight_flow(token, chat_id, product_id)
    end
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    case SettingsStore.get() do
      %{telegram_token: token} when is_binary(token) and byte_size(token) > 0 ->
        poll_updates(token)
      _ ->
        :ok
    end

    schedule_poll(poll_interval())
    {:noreply, state}
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__)[:poll_interval_ms] || 1200
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp poll_updates(token) do
    offset = get_offset()
    url = "https://api.telegram.org/bot#{token}/getUpdates?timeout=#{poll_timeout()}&offset=#{offset}"

    case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        handle_updates(token, Jason.decode!(body))
      {:ok, %Finch.Response{status: status, body: body}} ->
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
      text == "/start" ->
        delete_message(token, chat_id, msg_id)
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

  # my_chat_member, edited_message, callback_query va boshqa update turlarini e'tiborsiz qoldirish
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
          setup_prompt(token, chat_id, "API KEY qabul qilindi. Endi API SECRET ni kiriting (15 belgi):")
        else
          setup_prompt(token, chat_id, "API KEY noto'g'ri (15 ta harf/raqam kerak). Qaytadan kiriting:")
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
              delete_setup_prompt(token, chat_id)
              clear_temp(chat_id)
              set_state(chat_id, "ready")
              upsert_session(chat_id, combined, user)
              send_message(token, chat_id, "Ulandi. /batch buyrug'ini bering.")
            else
              setup_prompt(token, chat_id, "API SECRET noto'g'ri (15 ta harf/raqam kerak). Qaytadan kiriting:")
            end
        end

      "awaiting_weight" ->
        case parse_weight(text) do
          {:ok, weight} ->
            delete_message(token, chat_id, msg_id)
            product_id = get_temp(chat_id, "pending_product")
            if product_id do
              process_print(token, chat_id, product_id, weight, true)
            else
              send_message(token, chat_id, "Mahsulot topilmadi. /batch bosing.")
            end
          :error ->
            send_message(token, chat_id, "Vazn noto'g'ri. Iltimos kg ko'rinishida kiriting (masalan 12.345).")
        end

      _ ->
        :ok
    end
  end

  defp send_batch_prompt(token, chat_id) do
    delete_flow_msg(token, chat_id)
    delete_temp(chat_id, "pending_product")
    delete_temp(chat_id, "warehouse")
    delete_temp(chat_id, "batch_active")
    set_state(chat_id, "ready")
    put_temp(chat_id, "inline_mode", "product")
    keyboard = %{
      "inline_keyboard" => [[%{"text" => "Mahsulot tanlash", "switch_inline_query_current_chat" => ""}]]
    }
    mid = send_message(token, chat_id, "Mahsulot tanlash uchun pastdagi tugmani bosing.", keyboard)
    put_temp(chat_id, "flow_msg_id", mid)
  end

  defp stop_batch(token, chat_id) do
    product_id = get_temp(chat_id, "pending_product")
    clear_batch_msgs(token, chat_id)
    delete_flow_msg(token, chat_id)
    clear_temp(chat_id)
    set_state(chat_id, "ready")
    if product_id do
      send_message(token, chat_id, "Batch tugatildi (#{product_id}). Yangi batch uchun /batch bosing.")
    else
      send_message(token, chat_id, "Batch tugatildi. Yangi batch uchun /batch bosing.")
    end
  end

  defp send_warehouse_prompt(token, chat_id) do
    put_temp(chat_id, "inline_mode", "warehouse")
    keyboard = %{
      "inline_keyboard" => [[%{"text" => "Ombor tanlash", "switch_inline_query_current_chat" => "wh " }]]
    }
    send_message(token, chat_id, "Ombor tanlang:", keyboard)
  end

  defp handle_warehouse_selection(token, chat_id, warehouse) do
    product_id = get_temp(chat_id, "pending_product")
    if is_binary(product_id) and String.trim(product_id) != "" do
      put_temp(chat_id, "warehouse", warehouse)
      put_temp(chat_id, "batch_active", "true")
      put_temp(chat_id, "batch_count", 0)
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
        "inline_keyboard" => [[%{"text" => "Mahsulot tanlash", "switch_inline_query_current_chat" => ""}]]
      }
      flow_mid = get_temp(chat_id, "flow_msg_id")
      if flow_mid do
        edit_message(token, chat_id, flow_mid, "Ombor: #{warehouse}\nEndi mahsulot tanlang:", keyboard)
      else
        mid = send_message(token, chat_id, "Ombor: #{warehouse}\nEndi mahsulot tanlang:", keyboard)
        put_temp(chat_id, "flow_msg_id", mid)
      end
    end
  end

  defp handle_product_selection(token, chat_id, product_id) do
    put_temp(chat_id, "pending_product", product_id)
    set_state(chat_id, "awaiting_warehouse")
    put_temp(chat_id, "inline_mode", "warehouse")

    item_name = case Cache.get_item(product_id) do
      nil -> product_id
      item -> Map.get(item, :item_name) || product_id
    end

    keyboard = %{
      "inline_keyboard" => [[%{"text" => "Ombor tanlash", "switch_inline_query_current_chat" => "wh "}]]
    }

    flow_mid = get_temp(chat_id, "flow_msg_id")
    if flow_mid do
      edit_message(token, chat_id, flow_mid, "Mahsulot: #{item_name}\nOmbor tanlang:", keyboard)
    else
      mid = send_message(token, chat_id, "Mahsulot: #{item_name}\nOmbor tanlang:", keyboard)
      put_temp(chat_id, "flow_msg_id", mid)
    end
  end

  @low_stock_threshold 10

  defp begin_weight_flow(token, chat_id, product_id) do
    warehouse = get_temp(chat_id, "warehouse") || get_setting(:warehouse)
    qty = stock_qty(product_id, warehouse)

    uom =
      case Cache.get_item(product_id) do
        nil -> "dona"
        item -> Map.get(item, :stock_uom) || "dona"
      end

    cond do
      qty == :unknown ->
        do_weight_flow(token, chat_id, product_id)

      qty <= 0 ->
        send_message(token, chat_id,
          "Omborda mahsulot tugadi (#{product_id} → #{warehouse}).\n" <>
          "Boshqa ombor tanlash uchun /batch bosing.")
        delete_temp(chat_id, "batch_active")
        set_state(chat_id, "ready")

      qty <= @low_stock_threshold ->
        qty_str = if is_float(qty), do: :erlang.float_to_binary(qty, decimals: 2), else: to_string(qty)
        send_message(token, chat_id, "Diqqat: omborda faqat #{qty_str} #{uom} qoldi!")
        do_weight_flow(token, chat_id, product_id)

      true ->
        do_weight_flow(token, chat_id, product_id)
    end
  end

  defp stock_qty(product_id, warehouse) when is_binary(warehouse) do
    case Cache.warehouses_for_item(product_id) do
      {:ok, qty_map} -> Map.get(qty_map, warehouse, 0) || 0
      :no_cache -> :unknown
    end
  end
  defp stock_qty(_, _), do: :unknown

  defp do_weight_flow(token, chat_id, product_id) do
    delete_flow_msg(token, chat_id)
    case core_command(chat_id, "scale_read", %{}, 4000) do
      {:ok, %{"weight" => weight}} when is_number(weight) ->
        process_print(token, chat_id, product_id, weight, false)
      {:ok, %{weight: weight}} when is_number(weight) ->
        process_print(token, chat_id, product_id, weight, false)
      {:ok, _} ->
        prompt_manual_weight(token, chat_id, product_id)
      {:error, reason} ->
        if allow_simulation?() do
          prompt_manual_weight(token, chat_id, product_id)
        else
          ErpClient.create_log(%{
            "device_id" => device_id(),
            "action" => "error",
            "status" => "Error",
            "message" => "#{reason}"
          })
          send_message(token, chat_id, friendly_error(reason))
        end
    end
  end

  defp prompt_manual_weight(token, chat_id, product_id) do
    put_temp(chat_id, "pending_product", product_id)
    set_state(chat_id, "awaiting_weight")
    track_batch_msg(chat_id, send_message(token, chat_id, "Tarozi topilmadi. Vaznni kiriting (masalan 12.345):"))
  end

  defp process_print(token, chat_id, product_id, weight, manual?) do
    with {:ok, epc} <- next_epc_checked() do
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

      print_result = core_command(chat_id, "print_label", print_payload, 8000)
      print_ok = match?({:ok, _}, print_result)
      print_error = case print_result do
        {:error, reason} -> to_string(reason)
        _ -> nil
      end

      rfid_result =
        if print_ok or allow_simulation?() do
          core_command(chat_id, "rfid_write", %{"epc" => epc}, 6000)
        else
          {:error, "printer not ready"}
        end
      rfid_ok = match?({:ok, _}, rfid_result)
      rfid_error = case rfid_result do
        {:error, reason} -> to_string(reason)
        _ -> nil
      end

      simulated = manual? or allow_simulation?()

      warehouse = get_chat_warehouse(chat_id) || get_setting(:warehouse)
      draft_result =
        if print_ok or simulated do
          case ErpClient.create_draft(%{
            "product_id" => product_id,
            "warehouse" => warehouse,
            "weight_kg" => weight,
            "epc_code" => epc
          }) do
            {:ok, data} ->
              Logger.info("Stock Entry draft created: #{inspect(data["data"]["name"])}")
              :ok
            {:error, reason} ->
              Logger.warning("Stock Entry draft FAILED: #{inspect(reason)}")
              {:error, reason}
          end
        else
          {:error, "printer failed"}
        end

      ErpClient.create_log(%{
        "device_id" => device_id(chat_id),
        "action" => "print_label",
        "status" => if(print_ok, do: "Success", else: "Error"),
        "product_id" => product_id,
        "message" => print_ok && "Printed EPC #{epc}" || "Print skipped: #{print_error}"
      })

      draft_label = case draft_result do
        :ok -> "Draft OK"
        {:error, reason} -> "Draft xato: #{reason}"
      end

      result_text =
        cond do
          not print_ok and not simulated ->
            "Printer xato: #{print_error}"

          rfid_ok ->
            "#{weight} kg | #{draft_label}"

          simulated ->
            "#{weight} kg | #{draft_label}"

          true ->
            "#{weight} kg | #{draft_label} | RFID xato"
        end

      increment_batch_count(chat_id)
      maybe_continue_batch(token, chat_id, product_id, result_text)
    else
      {:error, reason} ->
        ErpClient.create_log(%{
          "device_id" => device_id(),
          "action" => "error",
          "status" => "Error",
          "message" => "#{reason}"
        })
        maybe_continue_batch(token, chat_id, product_id, friendly_error(reason))
    end
  end

  defp maybe_continue_batch(token, chat_id, product_id, result_text) do
    if get_temp(chat_id, "batch_active") == "true" do
      warehouse = get_temp(chat_id, "warehouse")
      count = get_temp(chat_id, "batch_count") || 0

      text =
        "✓ #{result_text}\n" <>
        "Batch: #{product_id} → #{warehouse} (#{count} ta)\n" <>
        "Kutyapman...\nTugatish uchun /stop"

      flow_mid = get_temp(chat_id, "flow_msg_id")
      if flow_mid do
        edit_message(token, chat_id, flow_mid, text)
      else
        mid = send_message(token, chat_id, text)
        put_temp(chat_id, "flow_msg_id", mid)
      end

      Process.send_after(self(), {:batch_next, token, chat_id, product_id}, 2000)
    end
  end

  defp next_epc_checked(retries \\ 5)
  defp next_epc_checked(0), do: {:error, "EPC conflict"}
  defp next_epc_checked(retries) when retries > 0 do
    with {:ok, epc} <- EpcGenerator.next() do
      case ErpClient.epc_exists?(epc) do
        {:ok, _} -> next_epc_checked(retries - 1)
        :not_found -> {:ok, epc}
        {:error, _} -> {:ok, epc}
      end
    end
  end

  defp parse_weight(text) do
    sanitized = String.replace(text || "", ",", ".") |> String.trim()
    case Float.parse(sanitized) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp allow_simulation? do
    case System.get_env("LCE_SIMULATE_DEVICES") || System.get_env("LCE_SIMULATE") do
      nil -> false
      "" -> false
      val ->
        String.downcase(val) in ["1", "true", "yes", "y", "on"]
    end
  end

  defp friendly_error(reason) do
    text = to_string(reason || "")
    cond do
      String.contains?(text, "offline") ->
        "Xato: Core agent offline. Qurilma ishlayotganini tekshiring."
      String.contains?(text, "timeout") ->
        "Xato: Core javob bermadi (timeout)."
      true ->
        "Xato: #{text}"
    end
  end

  defp device_id(chat_id \\ nil) do
    get_setting(:device_id) || (chat_id && "LCE-#{chat_id}") || "LCE-DEVICE"
  end

  defp core_command(chat_id, name, payload, timeout_ms) do
    target = core_device_id(chat_id)
    CoreHub.command(target, name, payload, timeout_ms)
  end

  defp core_device_id(_chat_id) do
    get_setting(:device_id)
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

  defp get_products_cache(chat_id) do
    now = System.system_time(:millisecond)
    case :ets.lookup(@temp_table, {chat_id, :products}) do
      [{{^chat_id, :products}, {ts, products}}] when now - ts < @products_cache_ttl_ms ->
        {:ok, products}
      _ ->
        :miss
    end
  end

  defp put_products_cache(chat_id, products) do
    :ets.insert(@temp_table, {{chat_id, :products}, {System.system_time(:millisecond), products}})
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

  defp valid_api_credential?(value) do
    is_binary(value) and String.length(value) == 15 and Regex.match?(~r/^[a-zA-Z0-9]+$/, value)
  end

  defp normalize_erp_url(url) do
    base =
      url
      |> String.trim()
      |> ensure_scheme()
      |> String.trim_trailing("/")

    case System.get_env("LCE_HOST_ALIAS") do
      nil -> base
      "" -> base
      alias_host ->
        case URI.parse(base) do
          %URI{host: host} = uri when host in ["localhost", "127.0.0.1"] ->
            uri
            |> Map.put(:host, alias_host)
            |> URI.to_string()
          _ ->
            base
        end
    end
  end

  defp ensure_scheme(base) do
    if String.starts_with?(base, ["http://", "https://"]) do
      base
    else
      "http://" <> base
    end
  end

  defp put_temp(chat_id, key, value) do
    :ets.insert(@temp_table, {{chat_id, key}, value})
  end

  defp get_temp(chat_id, key) do
    case :ets.lookup(@temp_table, {chat_id, key}) do
      [{{^chat_id, ^key}, value}] -> value
      _ -> nil
    end
  end

  defp delete_temp(chat_id, key) do
    :ets.delete(@temp_table, {chat_id, key})
  end

  defp clear_temp(chat_id) do
    :ets.match_delete(@temp_table, {{chat_id, :_}, :_})
  end

  defp send_message(token, chat_id, text, reply_markup \\ nil) do
    url = "https://api.telegram.org/bot#{token}/sendMessage"
    payload = %{"chat_id" => chat_id, "text" => text}
    payload = if reply_markup, do: Map.put(payload, "reply_markup", reply_markup), else: payload
    body = Jason.encode!(payload)

    case Finch.build(:post, url, [{"content-type", "application/json"}], body)
         |> Finch.request(TitanBridgeFinch) do
      {:ok, %{body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"ok" => true, "result" => %{"message_id" => mid}}} -> mid
          _ -> nil
        end
      {:error, err} ->
        Logger.warning("sendMessage failed: #{inspect(err)}")
        nil
    end
  end

  defp edit_message(token, chat_id, message_id, text, reply_markup \\ nil) do
    url = "https://api.telegram.org/bot#{token}/editMessageText"
    payload = %{"chat_id" => chat_id, "message_id" => message_id, "text" => text}
    payload = if reply_markup, do: Map.put(payload, "reply_markup", reply_markup), else: payload
    body = Jason.encode!(payload)

    Finch.build(:post, url, [{"content-type", "application/json"}], body)
    |> Finch.request(TitanBridgeFinch)
    |> case do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("editMessageText failed: #{inspect(err)}")
    end
  end

  defp answer_callback(token, callback_id, text \\ nil) do
    url = "https://api.telegram.org/bot#{token}/answerCallbackQuery"
    payload = %{"callback_query_id" => callback_id}
    payload = if text, do: Map.put(payload, "text", text), else: payload
    body = Jason.encode!(payload)

    Finch.build(:post, url, [{"content-type", "application/json"}], body)
    |> Finch.request(TitanBridgeFinch)
    |> case do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("answerCallbackQuery failed: #{inspect(err)}")
    end
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
              case Cache.warehouses_for_item(product_id) do
                {:ok, qmap} ->
                  whs = Cache.list_warehouses()
                        |> Enum.filter(fn row ->
                          Map.has_key?(qmap, row.name) and not row.disabled and not row.is_group
                        end)
                  {whs, qmap}
                :no_cache ->
                  case ErpClient.list_warehouses_for_product(product_id) do
                    {:ok, rows} -> {rows, %{}}
                    _ -> {[], %{}}
                  end
              end
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

          warehouses
          |> Enum.filter(fn row ->
            name = String.downcase(to_string(Map.get(row, :warehouse_name) || Map.get(row, "warehouse_name") || ""))
            code = String.downcase(to_string(Map.get(row, :name) || Map.get(row, "name") || ""))
            q == "" or String.contains?(name, q) or String.contains?(code, q)
          end)
          |> Enum.take(50)
          |> Enum.with_index()
          |> Enum.map(fn {row, idx} ->
            title = Map.get(row, :warehouse_name) || Map.get(row, "warehouse_name") || Map.get(row, :name) || Map.get(row, "name")
            code = Map.get(row, :name) || Map.get(row, "name") || ""
            qty = Map.get(qty_map, code, 0)
            qty_str = if is_float(qty), do: :erlang.float_to_binary(qty, decimals: 2), else: to_string(qty)
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
              name = String.downcase(to_string(Map.get(item, :item_name) || Map.get(item, "item_name") || ""))
              code = String.downcase(to_string(Map.get(item, :name) || Map.get(item, "name") || ""))
              String.contains?(name, q) or String.contains?(code, q)
            end
          end)
          |> Enum.take(50)
          |> Enum.with_index()
          |> Enum.map(fn {item, idx} ->
            title = Map.get(item, :item_name) || Map.get(item, "item_name") || Map.get(item, :name) || Map.get(item, "name")
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

    url = "https://api.telegram.org/bot#{token}/answerInlineQuery"
    payload = %{
      "inline_query_id" => query_id,
      "results" => results,
      "cache_time" => 1,
      "is_personal" => true
    }
    body = Jason.encode!(payload)

    Finch.build(:post, url, [{"content-type", "application/json"}], body)
    |> Finch.request(TitanBridgeFinch)
    |> case do
      {:ok, _} -> :ok
      {:error, err} -> Logger.warning("answerInlineQuery failed: #{inspect(err)}")
    end
  end

  defp delete_message(token, chat_id, msg_id) do
    url = "https://api.telegram.org/bot#{token}/deleteMessage"
    payload = Jason.encode!(%{"chat_id" => chat_id, "message_id" => msg_id})
    Finch.build(:post, url, [{"content-type", "application/json"}], payload)
    |> Finch.request(TitanBridgeFinch)
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp set_state(chat_id, state) do
    :ets.insert(@state_table, {chat_id, state})
  end

  defp get_state(chat_id) do
    case :ets.lookup(@state_table, chat_id) do
      [{^chat_id, state}] -> state
      _ -> "none"
    end
  end

  defp get_offset do
    case :ets.lookup(@temp_table, :offset) do
      [{:offset, val}] -> val
      _ -> 0
    end
  end

  defp set_offset(%{"update_id" => id}) do
    :ets.insert(@temp_table, {:offset, id + 1})
  end
  defp set_offset(_), do: :ok
end
