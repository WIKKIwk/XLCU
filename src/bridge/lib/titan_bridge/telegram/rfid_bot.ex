defmodule TitanBridge.Telegram.RfidBot do
  @moduledoc """
  RFID Telegram bot — controls UHF reader and auto-submits
  matching Stock Entry drafts in ERPNext.

  Flow:
    /start  → setup wizard: ERP URL → API key → API secret
    /scan   → loads drafts, starts RFID inventory, listens for tags
    /submit → manual submit (no UHF required): pick a draft via inline menu and submit
    /stop   → stops RFID inventory and scanning
    /status → shows current state + RFID reader status
    /list   → lists pending drafts with EPC
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias TitanBridge.{SettingsStore, ErpClient, RfidListener, EpcRegistry, Cache, ErpSyncWorker}
  alias TitanBridge.Repo
  alias TitanBridge.Cache.StockDraft
  alias TitanBridge.Telegram.{ChatState, SetupUtils, Transport}

  @state_table :rfid_tg_state
  @temp_table :rfid_tg_temp
  @inflight_table :rfid_tg_inflight
  @inflight_drafts_table :rfid_tg_inflight_drafts
  @miss_table :rfid_tg_miss
  @submitted_table :rfid_tg_submitted
  @submitted_drafts_table :rfid_tg_submitted_drafts
  @poll_default_ms 1200
  @poll_timeout_default 25
  @miss_ttl_default_ms 2_000
  @drafts_cache_ttl_ms 60_000
  @draft_refresh_default_ms 180_000
  @draft_sync_timeout_default_ms 60_000
  @submit_page_size 8

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    ChatState.init_tables!(@state_table, @temp_table)
    init_runtime_tables!()
    :ok = RfidListener.subscribe(self())
    schedule_poll(poll_interval())
    if draft_refresh_interval_ms() > 0, do: schedule_draft_refresh(draft_refresh_interval_ms())
    Logger.info("RFID bot listener subscribed (persistent mode)")
    {:ok, %{poll_inflight: false, draft_refresh_inflight: false}}
  end

  # --- Telegram Polling ---

  @impl true
  def handle_info(:poll, %{poll_inflight: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case SettingsStore.get() do
      %{rfid_telegram_token: token} when is_binary(token) and byte_size(token) > 0 ->
        run_poll_async(token)
        {:noreply, Map.put(state, :poll_inflight, true)}

      _ ->
        schedule_poll(poll_interval())
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_done, state) do
    schedule_poll(poll_interval())
    {:noreply, Map.put(state, :poll_inflight, false)}
  end

  @impl true
  def handle_info(:draft_refresh_tick, %{draft_refresh_inflight: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:draft_refresh_tick, state) do
    run_draft_refresh_async(full_refresh: false)
    {:noreply, Map.put(state, :draft_refresh_inflight, true)}
  end

  @impl true
  def handle_info({:draft_refresh_done, {:error, reason}}, state) do
    Logger.warning("RFID draft cache periodic refresh xato: #{inspect(reason)}")
    if draft_refresh_interval_ms() > 0, do: schedule_draft_refresh(draft_refresh_interval_ms())
    {:noreply, Map.put(state, :draft_refresh_inflight, false)}
  end

  @impl true
  def handle_info({:draft_refresh_done, _result}, state) do
    if draft_refresh_interval_ms() > 0, do: schedule_draft_refresh(draft_refresh_interval_ms())
    {:noreply, Map.put(state, :draft_refresh_inflight, false)}
  end

  # --- RFID Tag Event ---

  @impl true
  def handle_info({:rfid_tag, epc}, state) do
    handle_tag_scan(epc)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Telegram API ---

  defp run_poll_async(token) do
    parent = self()

    Task.start(fn ->
      try do
        poll_updates(token)
      rescue
        err ->
          Logger.debug("RFID bot poll task error: #{Exception.message(err)}")
      catch
        kind, reason ->
          Logger.debug("RFID bot poll task error: #{inspect({kind, reason})}")
      after
        send(parent, :poll_done)
      end
    end)
  end

  defp run_draft_refresh_async(opts \\ []) do
    parent = self()
    token = Keyword.get(opts, :token)
    chat_id = Keyword.get(opts, :chat_id)
    full_refresh = Keyword.get(opts, :full_refresh, true)

    Task.start(fn ->
      result = refresh_draft_cache(full_refresh)

      if is_binary(token) and token != "" and is_integer(chat_id) do
        case result do
          {:ok, %{drafts: drafts, epcs: epcs}} ->
            send_message(
              token,
              chat_id,
              "Draft cache saqlandi: #{drafts} ta draft, #{epcs} ta EPC."
            )

          {:error, reason} ->
            send_message(token, chat_id, "Draft cache yuklanmadi: #{inspect(reason)}")
        end
      end

      send(parent, {:draft_refresh_done, result})
    end)
  end

  defp poll_updates(token) do
    offset = get_offset()
    timeout = poll_timeout()

    case Transport.get_updates(token, offset, timeout, receive_timeout: (timeout + 5) * 1000) do
      {:ok, updates} ->
        Enum.each(updates, fn upd ->
          set_offset(upd)
          handle_update(token, upd)
        end)

      {:error, err} ->
        Logger.debug("RFID bot poll error: #{inspect(err)}")
    end
  end

  defp handle_update(token, %{
         "message" =>
           %{"text" => text, "chat" => %{"id" => chat_id}, "message_id" => msg_id} = msg
       }) do
    raw = String.trim(text || "")
    tokens = String.split(raw, ~r/\s+/, trim: true)
    command_token = List.first(tokens) || ""

    # "/command@botname" → "/command"
    cmd = command_token |> String.split("@") |> hd() |> String.downcase()
    args = tokens |> Enum.drop(1) |> Enum.join(" ") |> String.trim()
    user = msg["from"] || %{}

    user_id =
      case user do
        %{"id" => id} when is_integer(id) -> id
        _ -> nil
      end

    cond do
      cmd == "/start" or cmd == "/reset" ->
        delete_message(token, chat_id, msg_id)
        reset_chat_for_setup(token, chat_id)
        set_state(chat_id, "awaiting_erp_url")
        setup_prompt(token, chat_id, "ERP manzilini kiriting:")

      cmd == "/submit" ->
        delete_message(token, chat_id, msg_id)

        if args != "" do
          handle_submit_selection(token, chat_id, user_id, args)
        else
          handle_submit_prompt(token, chat_id, user_id)
        end

      cmd == "/scan" ->
        delete_message(token, chat_id, msg_id)
        handle_scan(token, chat_id)

      cmd == "/stop" ->
        delete_message(token, chat_id, msg_id)
        handle_stop(token, chat_id)

      cmd == "/status" ->
        delete_message(token, chat_id, msg_id)
        handle_status(token, chat_id)

      cmd == "/list" ->
        delete_message(token, chat_id, msg_id)
        handle_list(token, chat_id)

      cmd == "/cache" ->
        delete_message(token, chat_id, msg_id)
        handle_cache(token, chat_id)

      cmd == "/report" ->
        delete_message(token, chat_id, msg_id)
        handle_report(token, chat_id)

      String.starts_with?(text, "submit_draft:") ->
        delete_message(token, chat_id, msg_id)
        name = text |> String.replace_prefix("submit_draft:", "") |> String.trim()
        handle_submit_selection(token, chat_id, user_id, name)

      String.trim(text) != "" ->
        handle_state_input(token, chat_id, String.trim(text), msg_id, user)

      true ->
        :ok
    end
  end

  defp handle_update(token, %{"inline_query" => inline_query}) do
    query_id = inline_query["id"]
    query_text = String.trim(inline_query["query"] || "")
    from = inline_query["from"] || %{}
    user_id = from["id"]

    answer_inline_query(token, query_id, query_text, user_id)
  end

  defp handle_update(token, %{"callback_query" => cb}) do
    chat_id = cb["message"]["chat"]["id"]
    cb_id = cb["id"]
    data = cb["data"] || ""
    msg_id = cb["message"]["message_id"]

    user_id =
      case cb do
        %{"from" => %{"id" => id}} when is_integer(id) -> id
        _ -> nil
      end

    case data do
      "retry_scan" ->
        answer_callback(token, cb_id, "Tekshirilmoqda...")
        delete_message(token, chat_id, msg_id)
        handle_scan(token, chat_id)

      "retry_submit" ->
        answer_callback(token, cb_id, "Tekshirilmoqda...")
        delete_message(token, chat_id, msg_id)
        handle_submit_prompt(token, chat_id, user_id)

      "draft_refresh" ->
        answer_callback(token, cb_id, "Yangilanmoqda...")
        page = submit_page(chat_id)
        show_submit_menu(token, chat_id, user_id, page, true, msg_id)

      "draft_page:" <> page_str ->
        answer_callback(token, cb_id)

        page =
          case Integer.parse(page_str) do
            {n, _} when n >= 0 -> n
            _ -> 0
          end

        show_submit_menu(token, chat_id, user_id, page, false, msg_id)

      "submit_draft:" <> name ->
        answer_callback(token, cb_id, "Submit qilinyapti...")
        name = String.trim(name)
        # Make sure progress/result edits the message the user clicked.
        put_temp(chat_id, "submit_flow_msg_id", msg_id)
        handle_submit_selection(token, chat_id, user_id, name)

      _ ->
        answer_callback(token, cb_id)
    end
  end

  defp handle_update(_token, _update), do: :ok

  # --- Setup Wizard (same as Zebra bot) ---

  defp reset_chat_for_setup(token, chat_id) do
    # If the bot was scanning, stop it first so the setup wizard doesn't compete with scan flow.
    if get_state(chat_id) == "scanning" do
      rfid_inventory_stop()
    end

    delete_setup_prompt(token, chat_id)
    clear_temp(chat_id)
  end

  defp handle_state_input(token, chat_id, text, msg_id, _user) do
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
              delete_setup_prompt(token, chat_id)
              clear_temp(chat_id)
              set_state(chat_id, "ready")

              send_message(
                token,
                chat_id,
                "Ulandi!\n\n" <>
                  "/scan — skanerlashni boshlash\n" <>
                  "/list — draft'lar ro'yxati\n" <>
                  "/status — holat"
              )

              send_message(token, chat_id, "Draft cache ERPNext dan yuklanmoqda...")
              run_draft_refresh_async(token: token, chat_id: chat_id, full_refresh: true)
            else
              setup_prompt(
                token,
                chat_id,
                "API SECRET noto'g'ri (15 ta harf/raqam kerak). Qaytadan kiriting:"
              )
            end
        end

      _ ->
        :ok
    end
  end

  # --- /scan: ERPNext tekshir + RFID inventory boshlash ---

  defp handle_scan(token, chat_id) do
    state = get_state(chat_id)
    settings = SettingsStore.get()
    rfid_url = settings && settings.rfid_url
    {_rfid_connected, inventory_running} = rfid_reader_status(rfid_url)

    cond do
      state == "scanning" and inventory_running ->
        send_message(token, chat_id, "Allaqachon skaner rejimida. /stop bilan to'xtating.")

      state == "scanning" and not inventory_running ->
        # Web/TUI orqali stop qilingan bo'lsa, bot ichidagi stale state ni tiklaymiz.
        set_state(chat_id, "ready")
        start_scan_with_erp_check(token, chat_id, :recovered)

      state != "scanning" and inventory_running ->
        # Inventory tashqaridan allaqachon boshlangan: bot oqimiga ulab qo'yamiz.
        put_temp(chat_id, "submitted_count", get_temp(chat_id, "submitted_count") || 0)
        set_state(chat_id, "scanning")
        RfidListener.subscribe(self())
        Logger.info("RFID bot scan attached to already-running inventory (chat=#{chat_id})")

        send_message(
          token,
          chat_id,
          "RFID inventory allaqachon ishlayapti. Bot skaner rejimiga qayta ulandi.\n" <>
            "To'xtatish: /stop"
        )

      true ->
        start_scan_with_erp_check(token, chat_id, :fresh)
    end
  end

  defp start_scan_with_erp_check(token, chat_id, mode) do
    case ErpClient.ping() do
      {:ok, _} ->
        if mode == :recovered do
          send_message(
            token,
            chat_id,
            "Skaner web/tashqi boshqaruv orqali to'xtatilgan edi. Qayta ishga tushirilmoqda..."
          )
        end

        case refresh_draft_cache(true) do
          {:ok, %{drafts: drafts, epcs: epcs}} ->
            send_message(
              token,
              chat_id,
              "Draft cache saqlandi: #{drafts} ta draft, #{epcs} ta EPC."
            )

            do_scan(token, chat_id)

          {:error, reason} ->
            keyboard = %{
              "inline_keyboard" => [
                [%{"text" => "Qayta urinish", "callback_data" => "retry_scan"}]
              ]
            }

            send_message(
              token,
              chat_id,
              "ERP ulandi, lekin draft cache yuklanmadi: #{inspect(reason)}\nQayta urinib ko'ring.",
              keyboard
            )
        end

      {:error, _} ->
        keyboard = %{
          "inline_keyboard" => [[%{"text" => "Qayta urinish", "callback_data" => "retry_scan"}]]
        }

        send_message(
          token,
          chat_id,
          "ERPNext bilan aloqa yo'q. Tekshirib qayta urinib ko'ring.",
          keyboard
        )
    end
  end

  # --- /submit: draft tanlash (inline menu) + submit ---

  defp handle_submit_prompt(token, chat_id, user_id \\ nil) do
    case ErpClient.ping() do
      {:ok, _} ->
        # Force refresh so newly created drafts show up immediately.
        clear_drafts_cache(chat_id, user_id)
        put_temp(chat_id, "inline_mode", "draft_submit")

        text =
          "Draft submit qilish uchun inline qidirishni bosing.\n" <>
            "Natijadan draft tanlang (bot chatga `submit_draft:<name>` yuboradi va uni o'chirib, submit qiladi)."

        keyboard = %{
          "inline_keyboard" => [
            [
              %{"text" => "Inline qidirish", "switch_inline_query_current_chat" => "draft "}
            ]
          ]
        }

        mid = send_message(token, chat_id, text, keyboard)
        put_temp(chat_id, "submit_flow_msg_id", mid)

      {:error, reason} ->
        keyboard = %{
          "inline_keyboard" => [[%{"text" => "Qayta urinish", "callback_data" => "retry_submit"}]]
        }

        send_message(
          token,
          chat_id,
          "ERPNext bilan aloqa yo'q.\nSabab: #{ErpClient.human_error(reason)}",
          keyboard
        )
    end
  end

  defp submit_page(chat_id) do
    case get_temp(chat_id, "submit_page") do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp show_submit_menu(token, chat_id, user_id, page, refresh?, flow_mid \\ nil)

  defp show_submit_menu(token, chat_id, user_id, page, refresh?, flow_mid)
       when is_integer(page) and page >= 0 do
    if refresh? do
      clear_drafts_cache(chat_id, user_id)
    end

    drafts =
      case get_drafts_cache(chat_id) do
        {:ok, rows} ->
          rows

        :miss ->
          rows = fetch_submit_drafts()
          put_drafts_cache(chat_id, rows)
          rows
      end

    if drafts == [] do
      send_message(token, chat_id, "Draft topilmadi. /list bilan tekshirib ko'ring.")
    else
      total = length(drafts)
      pages = max(div(total + @submit_page_size - 1, @submit_page_size), 1)
      page = min(page, pages - 1)
      put_temp(chat_id, "submit_page", page)

      text =
        "Draft tanlang (#{page + 1}/#{pages}):\n\n" <>
          "Agar inline qidirish yoqilgan bo'lsa, tugma orqali qidirishingiz mumkin."

      keyboard = build_submit_keyboard(drafts, page, pages)

      existing_mid =
        cond do
          is_integer(flow_mid) -> flow_mid
          true -> get_temp(chat_id, "submit_flow_msg_id")
        end

      mid =
        if is_integer(existing_mid) do
          _ = edit_message(token, chat_id, existing_mid, text, keyboard)
          existing_mid
        else
          send_message(token, chat_id, text, keyboard)
        end

      put_temp(chat_id, "submit_flow_msg_id", mid)
    end
  end

  defp show_submit_menu(token, chat_id, user_id, _page, refresh?, flow_mid) do
    show_submit_menu(token, chat_id, user_id, 0, refresh?, flow_mid)
  end

  defp build_submit_keyboard(drafts, page, pages) do
    start = page * @submit_page_size
    slice = drafts |> Enum.drop(start) |> Enum.take(@submit_page_size)

    draft_rows =
      slice
      |> Enum.map(fn d ->
        name = to_string(d.name || "")

        display_epc =
          (d.items || [])
          |> Enum.map(&Map.get(&1, :barcode))
          |> Enum.find(fn v -> is_binary(v) and String.trim(v) != "" end)

        display_epc =
          cond do
            is_binary(display_epc) and String.trim(display_epc) != "" ->
              String.trim(display_epc)

            true ->
              (d.epcs || [])
              |> Enum.find(fn v -> is_binary(v) and String.trim(v) != "" end)
              |> case do
                v when is_binary(v) -> String.trim(v)
                _ -> ""
              end
          end

        title =
          if display_epc != "" do
            display_epc |> String.slice(0, 24)
          else
            name |> String.slice(0, 24)
          end

        [%{"text" => title, "callback_data" => "submit_draft:" <> name}]
      end)

    nav_buttons =
      []
      |> then(fn acc ->
        if page > 0 do
          acc ++ [%{"text" => "Oldingi", "callback_data" => "draft_page:#{page - 1}"}]
        else
          acc
        end
      end)
      |> then(fn acc ->
        if page + 1 < pages do
          acc ++ [%{"text" => "Keyingi", "callback_data" => "draft_page:#{page + 1}"}]
        else
          acc
        end
      end)

    nav_row = if nav_buttons != [], do: [nav_buttons], else: []

    actions_row = [
      [
        %{"text" => "Yangilash", "callback_data" => "draft_refresh"},
        %{"text" => "Inline qidirish", "switch_inline_query_current_chat" => "draft "}
      ]
    ]

    %{"inline_keyboard" => draft_rows ++ nav_row ++ actions_row}
  end

  defp handle_submit_selection(token, chat_id, user_id, name) do
    name = String.trim(name || "")

    if name == "" do
      send_message(token, chat_id, "Draft tanlanmadi. /submit bilan qayta urinib ko'ring.")
    else
      keyboard = %{
        "inline_keyboard" => [
          [
            %{"text" => "Inline qidirish", "switch_inline_query_current_chat" => "draft "}
          ]
        ]
      }

      flow_mid = get_temp(chat_id, "submit_flow_msg_id")

      if is_integer(flow_mid) do
        _ = edit_message(token, chat_id, flow_mid, "Submit qilinmoqda: #{name} ...", keyboard)
      end

      # Draft items/EPC larni olish (cache cleanup uchun ham kerak).
      doc =
        case ErpClient.get_doc("Stock Entry", name) do
          {:ok, d} -> d
          _ -> %{}
        end

      case ErpClient.submit_stock_entry(name) do
        {:ok, _} ->
          # Cache cleanup: draft va EPC mappingni olib tashlash (scanner qayta submit qilmasin)
          Cache.delete_stock_draft(name)
          remember_submitted_draft(name)

          items = (doc || %{})["items"] || []

          remark_epc = extract_epc_from_remarks((doc || %{})["remarks"])

          if is_binary(remark_epc) and remark_epc != "" do
            Cache.delete_epc_mapping(normalize_epc(remark_epc))
          end

          Enum.each(items, fn item ->
            barcode = String.trim(item["barcode"] || "")
            batch = String.trim(item["batch_no"] || "")
            serial = String.trim(item["serial_no"] || "")

            serials =
              if serial != "" do
                serial
                |> String.split(~r/[\s,]+/, trim: true)
                |> Enum.map(&String.trim/1)
                |> Enum.filter(&(&1 != ""))
              else
                []
              end

            # Prefer barcode for new flow, but keep batch/serial for legacy drafts.
            epcs = Enum.filter([barcode, batch], &(&1 != "")) ++ serials

            Enum.each(epcs, fn raw ->
              epc = normalize_epc(raw)

              if epc != "" do
                remember_submitted(epc)
                Cache.delete_epc_mapping(epc)
              end
            end)
          end)

          clear_drafts_cache(chat_id, user_id)

          items_text =
            items
            |> Enum.map(fn i -> "#{i["item_code"]}: #{i["qty"]}" end)
            |> Enum.join(", ")

          msg =
            if items_text == "" do
              "#{name} submitted!"
            else
              "#{name} submitted!\n#{items_text}"
            end

          if is_integer(flow_mid) do
            _ = edit_message(token, chat_id, flow_mid, msg, keyboard)
          else
            send_message(token, chat_id, msg, keyboard)
          end

        {:error, reason} ->
          msg = "Submit xato: #{ErpClient.human_error(reason)}"

          if is_integer(flow_mid) do
            _ = edit_message(token, chat_id, flow_mid, msg, keyboard)
          else
            send_message(token, chat_id, msg, keyboard)
          end
      end
    end
  end

  defp clear_drafts_cache(chat_id, user_id) do
    delete_temp(chat_id, :drafts)

    if is_integer(user_id) and user_id != chat_id do
      delete_temp(user_id, :drafts)
    end
  end

  defp answer_inline_query(token, query_id, query_text, user_id) do
    query = String.downcase(query_text || "")
    inline_mode = get_temp(user_id, "inline_mode")

    # Support both: button prefill "draft " and manual typing.
    cleaned =
      query
      |> String.replace_prefix("draft", "")
      |> String.replace_prefix("se", "")
      |> String.replace_prefix("submit", "")

    q = String.trim(cleaned)

    # If user didn't run /submit, still allow searching drafts in inline mode.
    _ = inline_mode

    drafts =
      case get_drafts_cache(user_id) do
        {:ok, rows} ->
          rows

        :miss ->
          rows = fetch_submit_drafts()
          put_drafts_cache(user_id, rows)
          rows
      end

    results =
      drafts
      |> Enum.filter(fn d ->
        if q == "" do
          true
        else
          name = to_string(d.name || "")
          items = d.items || []

          items_text =
            items
            |> Enum.map(fn i -> "#{i.item_code}: #{i.qty}" end)
            |> Enum.join(" ")

          epcs =
            (d.epcs || [])
            |> Enum.join(" ")

          searchable = String.downcase(name <> " " <> items_text <> " " <> epcs)
          String.contains?(searchable, q)
        end
      end)
      |> Enum.take(50)
      |> Enum.with_index()
      |> Enum.map(fn {d, idx} ->
        name = to_string(d.name || "")

        display_epc =
          (d.items || [])
          |> Enum.map(&Map.get(&1, :barcode))
          |> Enum.find(fn v -> is_binary(v) and String.trim(v) != "" end)

        display_epc =
          cond do
            is_binary(display_epc) and String.trim(display_epc) != "" ->
              String.trim(display_epc)

            true ->
              (d.epcs || [])
              |> Enum.find(fn v -> is_binary(v) and String.trim(v) != "" end)
              |> case do
                v when is_binary(v) -> String.trim(v)
                _ -> ""
              end
          end

        title =
          if display_epc != "" do
            # User-friendly: show EPC from Stock Entry Detail.barcode as the primary label.
            display_epc
          else
            name
          end

        items =
          (d.items || [])
          |> Enum.map(fn i -> "#{i.item_code}: #{i.qty}" end)
          |> Enum.join(", ")

        desc =
          items
          |> String.replace(~r/\s+/, " ")
          |> String.trim()
          |> String.slice(0, 180)

        desc = if desc == "", do: "Draft", else: desc

        %{
          "type" => "article",
          "id" => "draft-#{idx}-#{name}",
          "title" => title,
          "description" => desc,
          "input_message_content" => %{
            # Old flow: selecting an inline result sends a hidden command-like message,
            # then the bot deletes it and submits the draft.
            "message_text" => "submit_draft:" <> name
          }
        }
      end)

    Transport.answer_inline_query(token, query_id, results, log_level: :debug)
  end

  defp do_scan(token, chat_id) do
    # RFID inventory boshlash — reader o'qiy boshlaydi
    case rfid_inventory_start() do
      :ok ->
        put_temp(chat_id, "submitted_count", 0)
        set_state(chat_id, "scanning")
        RfidListener.subscribe(self())
        Logger.info("RFID bot scan started (chat=#{chat_id})")

        send_message(
          token,
          chat_id,
          "RFID skaner ishlayapti!\n" <>
            "Mahsulotni reader ga tutib turing.\n" <>
            "Har bir o'qilgan EPC avtomatik ERPNext dan qidiriladi.\n\n" <>
            "To'xtatish: /stop"
        )

      {:error, reason} ->
        send_message(
          token,
          chat_id,
          "RFID reader bilan aloqa yo'q: #{reason}\n" <>
            "Reader ulangan va ishlayotganini tekshiring."
        )
    end
  end

  # --- /stop: RFID inventory to'xtatish ---

  defp handle_stop(token, chat_id) do
    if get_state(chat_id) == "scanning" do
      rfid_inventory_stop()

      submitted = get_temp(chat_id, "submitted_count") || 0
      set_state(chat_id, "ready")

      send_message(
        token,
        chat_id,
        "Skaner to'xtatildi.\n#{submitted} ta draft submit qilindi.\n\n/scan — qayta boshlash"
      )
    else
      send_message(token, chat_id, "Skaner ishlamayapti. /scan bilan boshlang.")
    end
  end

  # --- /status ---

  defp handle_status(token, chat_id) do
    state = get_state(chat_id)
    settings = SettingsStore.get()
    rfid_url = settings && settings.rfid_url

    {rfid_connected, inventory_running} = rfid_reader_status(rfid_url)

    erp_status =
      case ErpClient.ping() do
        {:ok, _} -> "ulangan"
        {:error, _} -> "ulanmagan"
      end

    text =
      "Bot: #{state}\n" <>
        "ERPNext: #{erp_status}\n" <>
        "RFID reader: #{if rfid_connected, do: "ulangan", else: "ulanmagan"}\n" <>
        "Inventory: #{if inventory_running, do: "ishlayapti", else: "to'xtatilgan"}"

    text =
      if state == "scanning" do
        submitted = get_temp(chat_id, "submitted_count") || 0
        text <> "\nSubmit qilindi: #{submitted} ta"
      else
        text
      end

    send_message(token, chat_id, text)
  end

  # --- /list ---

  defp handle_list(token, chat_id) do
    Task.start(fn -> do_handle_list(token, chat_id) end)
    :ok
  end

  defp do_handle_list(token, chat_id) do
    case get_drafts_cache(chat_id) do
      {:ok, drafts} ->
        send_drafts_list_message(token, chat_id, drafts)

      :miss ->
        case fetch_submit_drafts_detailed() do
          {:ok, drafts} ->
            put_drafts_cache(chat_id, drafts)
            send_drafts_list_message(token, chat_id, drafts)

          {:error, reason} ->
            send_message(token, chat_id, list_error_message(reason))
        end
    end
  end

  defp send_drafts_list_message(token, chat_id, drafts) when is_list(drafts) do
    if drafts == [] do
      send_message(token, chat_id, "EPC li draft topilmadi.")
    else
      lines =
        drafts
        |> Enum.take(20)
        |> Enum.map(fn d ->
          items =
            Enum.map(d.items, fn i ->
              epc = i.batch_no || i.serial_no || i.barcode
              sn = if epc, do: " [#{String.slice(epc, 0, 12)}...]", else: ""
              "#{i.item_code}: #{i.qty}#{sn}"
            end)
            |> Enum.join(", ")

          "#{d.name} — #{items}"
        end)
        |> Enum.join("\n")

      send_message(token, chat_id, "Draft'lar (#{length(drafts)}):\n\n#{lines}")
    end
  end

  defp list_error_message(reason) do
    cond do
      is_binary(reason) and String.starts_with?(reason, "ERP GET failed: 401") ->
        "ERPNext auth xato (401).\n" <>
          "API KEY/SECRET noto'g'ri yoki o'zgargan bo'lishi mumkin.\n\n" <>
          "/start yuborib qayta sozlang."

      true ->
        "Xato: #{ErpClient.human_error(reason)}"
    end
  end

  # --- /cache: Lokal cache dagi draftlar to'liq ma'lumoti (.log fayl) ---

  defp handle_cache(token, chat_id) do
    drafts = Cache.list_stock_drafts()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string()

    header = """
    ============================================
      RFID BOT — LOKAL CACHE HISOBOTI
      Sana: #{now}
      Jami draftlar: #{length(drafts)}
    ============================================

    """

    body =
      if drafts == [] do
        "  (cache bo'sh — draftlar topilmadi)\n"
      else
        drafts
        |> Enum.with_index(1)
        |> Enum.map(fn {draft, idx} ->
          data = draft.data || %{}
          items = data["items"] || []

          items_text =
            if items == [] do
              "    (items yuklanmagan)"
            else
              items
              |> Enum.with_index(1)
              |> Enum.map(fn {item, i} ->
                epc =
                  [item["barcode"] || "", item["batch_no"] || "", item["serial_no"] || ""]
                  |> Enum.map(&to_string/1)
                  |> Enum.map(&String.trim/1)
                  |> Enum.find(&(&1 != "")) || "-"

                "    #{i}. #{item["item_code"]} | qty: #{item["qty"]} | EPC: #{epc}"
              end)
              |> Enum.join("\n")
            end

          """
          -------- Draft ##{idx} --------
            Nomi:      #{draft.name}
            Status:    #{draft.docstatus}
            Maqsad:    #{draft.purpose || "-"}
            Sana:      #{draft.posting_date || "-"} #{draft.posting_time || ""}
            Ombor:     #{draft.to_warehouse || draft.from_warehouse || "-"}
            O'zgargan: #{draft.modified || "-"}
            Items:
          #{items_text}
          """
        end)
        |> Enum.join("\n")
      end

    # EPC mapping
    epc_section =
      case :ets.tab2list(:lce_cache_epc_drafts) do
        [] ->
          "\n  EPC MAPPING: (bo'sh)\n"

        entries ->
          epc_lines =
            entries
            |> Enum.map(fn {epc, info} ->
              "    #{epc} → #{info.name}"
            end)
            |> Enum.join("\n")

          "\n============================================\n" <>
            "  EPC → DRAFT MAPPING (#{length(entries)} ta)\n" <>
            "============================================\n\n" <>
            epc_lines <> "\n"
      end

    content = header <> body <> epc_section
    filename = "cache_#{Date.utc_today() |> Date.to_string()}.log"
    send_document(token, chat_id, filename, content, "Lokal cache: #{length(drafts)} ta draft")
  end

  # --- /report: O'qilgan EPC lar hisoboti (.log fayl) ---

  defp handle_report(token, chat_id) do
    import Ecto.Query
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string()

    # PostgreSQL dan barcha RFID o'qilgan EPC larni olish
    records =
      from(e in TitanBridge.Cache.EpcRegistry,
        where: e.source == "rfid",
        order_by: [desc: e.updated_at]
      )
      |> TitanBridge.Repo.all()

    scanned = Enum.filter(records, fn r -> r.status == "scanned" end)
    submitted = Enum.filter(records, fn r -> r.status == "submitted" end)

    header = """
    ============================================
      RFID BOT — O'QILGAN EPC HISOBOTI
      Sana: #{now}
      Jami uniq EPC: #{length(records)}
      Skan qilingan: #{length(scanned)}
      Submit qilingan: #{length(submitted)}
    ============================================

    """

    body =
      if records == [] do
        "  (hech qanday EPC o'qilmagan)\n"
      else
        records
        |> Enum.with_index(1)
        |> Enum.map(fn {r, idx} ->
          status_icon = if r.status == "submitted", do: "[OK]", else: "[--]"
          time = if r.updated_at, do: NaiveDateTime.to_string(r.updated_at), else: "-"

          "  #{String.pad_leading(Integer.to_string(idx), 4)}. #{status_icon} #{r.epc}  |  #{r.status}  |  #{time}"
        end)
        |> Enum.join("\n")
      end

    content = header <> body <> "\n"
    filename = "rfid_report_#{Date.utc_today() |> Date.to_string()}.log"
    send_document(token, chat_id, filename, content, "RFID: #{length(records)} ta uniq EPC")
  end

  # --- RFID Server API ---

  defp rfid_base_url do
    case SettingsStore.get() do
      %{rfid_url: url} when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        nil
    end
  end

  defp rfid_inventory_start do
    case rfid_base_url() do
      nil ->
        {:error, "RFID URL sozlanmagan"}

      base ->
        url = base <> "/api/inventory/start"

        case Finch.build(:post, url, [{"content-type", "application/json"}], "{}")
             |> Finch.request(TitanBridgeFinch, receive_timeout: 5000) do
          {:ok, %Finch.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Finch.Response{body: body}} ->
            {:error, "RFID: #{body}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp rfid_inventory_stop do
    case rfid_base_url() do
      nil ->
        :ok

      base ->
        url = base <> "/api/inventory/stop"

        Finch.build(:post, url, [{"content-type", "application/json"}], "{}")
        |> Finch.request(TitanBridgeFinch, receive_timeout: 5000)

        :ok
    end
  end

  defp rfid_reader_status(rfid_url) do
    if is_binary(rfid_url) and String.trim(rfid_url) != "" do
      base = String.trim_trailing(rfid_url, "/")

      case Finch.build(:get, base <> "/api/status")
           |> Finch.request(TitanBridgeFinch, receive_timeout: 3000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"status" => %{"connected" => connected, "inventoryStarted" => inv}}} ->
              {connected == true, inv == true}

            {:ok, _} ->
              {true, false}

            _ ->
              {false, false}
          end

        _ ->
          {false, false}
      end
    else
      {false, false}
    end
  end

  # --- RFID Tag Matching ---

  defp handle_tag_scan(raw_epc) do
    epc = normalize_epc(raw_epc)

    if epc == "" do
      :ok
    else
      cond do
        inflight?(epc) ->
          Logger.debug("RFID [#{epc}] SKIP: inflight")
          :ok

        recently_submitted?(epc) ->
          Logger.debug("RFID [#{epc}] SKIP: recently_submitted")
          :ok

        recently_missed?(epc) ->
          :ok

        true ->
          Logger.info("RFID [#{epc}] qidirish boshlandi...")
          case find_draft_by_epc(epc) do
            {:ok, draft_info} ->
              clear_miss(epc)
              name = draft_info.name
              Logger.info("RFID [#{epc}] TOPILDI -> #{name}")

              cond do
                recently_submitted_draft?(name) ->
                  remember_submitted(epc)
                  Cache.delete_epc_mapping(epc)
                  Logger.debug("RFID skip (draft submitted): #{name}")

                draft_inflight?(name) ->
                  Logger.debug("RFID [#{epc}] SKIP: draft_inflight #{name}")
                  :ok

                mark_inflight(epc) ->
                  if mark_draft_inflight(name) do
                    Logger.info("RFID [#{epc}] SUBMIT boshlandi: #{name}")
                    Task.start(fn -> search_and_submit(epc, draft_info) end)
                  else
                    clear_inflight(epc)
                    :ok
                  end

                true ->
                  :ok
              end

            :not_found ->
              Logger.debug("RFID [#{epc}] TOPILMADI (3 qatlam)")
              remember_miss(epc)
              :ok
          end
      end
    end
  end

  defp search_and_submit(epc, draft_info) do
    draft_name = draft_info.name

    try do
      token = get_rfid_token()
      chats = scanning_chats()
      Logger.info("RFID submit start: draft=#{draft_name} epc=#{epc} chats=#{length(chats)}")

      # Silent mode: even if /scan chat state is not active, still submit immediately.
      # Notifications are sent only when token+chat are available.
      do_submit(draft_name, draft_info.doc, epc, token, chats)
    after
      clear_inflight(epc)
      clear_draft_inflight(draft_name)
    end
  end

  # Gibrid qidirish: lokal cache → ERPNext fallback
  defp find_draft_by_epc(epc) do
    # 1-qatlam: ETS cache
    case Cache.find_draft_by_epc(epc) do
      {:ok, draft_info} ->
        Logger.info("RFID [#{epc}] 1-QATLAM ETS: TOPILDI -> #{draft_info.name}")
        {:ok, draft_info}

      :not_found ->
        Logger.debug("RFID [#{epc}] 1-QATLAM ETS: topilmadi, PostgreSQL ga o'tish...")
        # 2-qatlam: PostgreSQL
        case find_draft_by_epc_local_store(epc) do
          {:ok, draft_info} ->
            Logger.info("RFID [#{epc}] 2-QATLAM PG: TOPILDI -> #{draft_info.name}")
            {:ok, draft_info}

          :not_found ->
            Logger.debug("RFID [#{epc}] 2-QATLAM PG: topilmadi, ERP fallback ga o'tish...")
            # 3-qatlam: ERPNext API
            find_draft_by_epc_erp_fallback(epc)
        end
    end
  end

  defp find_draft_by_epc_local_store(epc) do
    try do
      drafts =
        StockDraft
        |> where([d], d.docstatus == 0)
        |> order_by([d], desc: d.updated_at)
        |> limit(500)
        |> Repo.all()

      Logger.debug("RFID [#{epc}] PG: #{length(drafts)} ta draft yuklandi")

      drafts
      |> Enum.find_value(:not_found, fn draft ->
        doc = draft.data || %{}
        summary = draft_from_doc(draft.name, doc)

        normalized_epcs =
          summary.epcs
          |> Enum.map(&normalize_epc/1)
          |> Enum.filter(&(&1 != ""))
          |> Enum.uniq()

        if Enum.member?(normalized_epcs, epc) do
          Logger.info("RFID [#{epc}] PG match: #{draft.name} epcs=#{inspect(Enum.take(normalized_epcs, 3))}")
          {:ok, %{name: draft.name, doc: doc}}
        else
          nil
        end
      end)
    rescue
      e ->
        Logger.warning("find_draft_by_epc_local_store error: #{inspect(e)}")
        :not_found
    end
  end

  defp find_draft_by_epc_erp_fallback(epc) do
    timeout = erp_fallback_timeout_ms()

    task =
      Task.async(fn ->
        ErpClient.find_open_draft_name_by_epc(epc)
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} ->
          Logger.info("RFID [#{epc}] 3-QATLAM ERP: javob olindi: #{inspect(value)}")
          value

        nil ->
          Logger.warning("RFID [#{epc}] 3-QATLAM ERP: TIMEOUT #{timeout}ms")
          :not_found
      end

    case result do
      {:ok, name} when is_binary(name) and name != "" ->
        doc =
          case ErpClient.get_doc("Stock Entry", name) do
            {:ok, d} when is_map(d) -> d
            _ -> %{"name" => name, "items" => []}
          end

        if draft_doc_open?(doc) do
          Logger.info("RFID [#{epc}] 3-QATLAM ERP: TOPILDI -> #{name}")
          {:ok, %{name: name, doc: doc}}
        else
          Logger.warning("RFID [#{epc}] 3-QATLAM ERP: draft ochiq emas: #{name}")
          :not_found
        end

      _ ->
        :not_found
    end
  rescue
    e ->
      Logger.warning("RFID ERP fallback rescue: #{inspect(e)}")
      :not_found
  catch
    :exit, reason ->
      Logger.warning("RFID ERP fallback exit: #{inspect(reason)}")
      :not_found
  end

  defp do_submit(name, doc, epc, token, chats) do
    if recently_submitted_draft?(name) do
      remember_submitted(epc)
      Cache.delete_epc_mapping(epc)
      Logger.debug("RFID submit skip (already submitted): #{name} EPC=#{epc}")
      :ok
    else
      case submit_with_retry(name) do
        {:ok, _} ->
          Task.start(fn -> EpcRegistry.mark_submitted(epc) end)
          remember_submitted(epc)
          remember_submitted_draft(name)
          cleanup_submitted_draft_local(name)
          # Lokal cache dan olib tashlaymiz — qayta submit bo'lmasin
          Cache.delete_epc_mapping(epc)
          Logger.info("RFID auto-submit: #{name} (EPC: #{epc})")

          items = (doc || %{})["items"] || []

          items_text =
            items
            |> Enum.map(fn i -> "#{i["item_code"]}: #{i["qty"]}" end)
            |> Enum.join(", ")

          submit_text =
            if String.trim(items_text) == "" do
              "#{name} submitted!\nEPC: #{String.slice(epc, 0, 16)}..."
            else
              "#{name} submitted!\n#{items_text}\nEPC: #{String.slice(epc, 0, 16)}..."
            end

          Enum.each(chats, fn chat_id ->
            old_count = get_temp(chat_id, "submitted_count") || 0
            put_temp(chat_id, "submitted_count", old_count + 1)

            send_message(token, chat_id, submit_text)
          end)

        {:error, reason} ->
          Logger.warning("RFID submit xato: #{name} — #{inspect(reason)}")

          if is_binary(token) and byte_size(token) > 0 and is_list(chats) and chats != [] do
            stop_scanning_erp_down(token, chats, reason)
          else
            :ok
          end
      end
    end
  end

  defp submit_with_retry(name) when is_binary(name) do
    max_retry = submit_retry_count()
    retry_ms = submit_retry_delay_ms()
    do_submit_with_retry(name, max_retry, retry_ms, 0)
  end

  defp do_submit_with_retry(name, max_retry, retry_ms, attempt) do
    case ErpClient.submit_stock_entry(name) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if retryable_submit_error?(reason) and attempt < max_retry do
          Process.sleep(retry_ms)
          do_submit_with_retry(name, max_retry, retry_ms, attempt + 1)
        else
          err
        end
    end
  end

  defp retryable_submit_error?(reason) do
    text =
      case reason do
        r when is_binary(r) -> r
        r -> inspect(r)
      end

    String.contains?(text, "QueryDeadlockError") or
      String.contains?(text, "Deadlock found when trying to get lock") or
      String.contains?(text, "Lock wait timeout exceeded")
  end

  defp submit_retry_count do
    case Integer.parse(to_string(System.get_env("LCE_RFID_SUBMIT_RETRY") || "")) do
      {n, _} when n >= 0 and n <= 10 -> n
      _ -> 2
    end
  end

  defp submit_retry_delay_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_SUBMIT_RETRY_MS") || "")) do
      {n, _} when n >= 10 and n <= 10_000 -> n
      _ -> 120
    end
  end

  defp cleanup_submitted_draft_local(name) when is_binary(name) and name != "" do
    # Keep local cache consistent immediately after successful submit,
    # otherwise stale docstatus=0 rows can be re-matched and re-submitted.
    try do
      _ = Repo.delete_all(from(d in StockDraft, where: d.name == ^name))
      Cache.delete_stock_draft(name)
      :ok
    rescue
      _ -> :ok
    end
  end

  defp cleanup_submitted_draft_local(_), do: :ok

  defp draft_doc_open?(doc) when is_map(doc) do
    value = doc["docstatus"] || doc[:docstatus]

    case value do
      0 -> true
      "0" -> true
      _ -> false
    end
  end

  defp draft_doc_open?(_), do: false

  defp stop_scanning_erp_down(token, chats, reason \\ nil) do
    rfid_inventory_stop()

    reason_text =
      case reason do
        nil -> nil
        other -> ErpClient.human_error(other)
      end

    Enum.each(chats, fn chat_id ->
      set_state(chat_id, "ready")

      keyboard = %{
        "inline_keyboard" => [[%{"text" => "Qayta urinish", "callback_data" => "retry_scan"}]]
      }

      send_message(
        token,
        chat_id,
        "ERPNext bilan muammo yuz berdi. Skaner to'xtatildi.\n" <>
          if(reason_text, do: "Sabab: #{reason_text}\n", else: "") <>
          "Tekshirib qayta urinib ko'ring.",
        keyboard
      )
    end)
  end

  # --- EPC Normalize ---

  defp normalize_epc(raw) do
    raw |> String.trim() |> String.upcase() |> String.replace(~r/[^0-9A-F]/, "")
  end

  # --- Scanning Chats ---

  defp scanning_chats do
    :ets.tab2list(@state_table)
    |> Enum.filter(fn {_chat_id, state} -> state == "scanning" end)
    |> Enum.map(fn {chat_id, _} -> chat_id end)
  end

  # --- State Helpers ---

  defp get_state(chat_id), do: ChatState.get_state(@state_table, chat_id, "idle")

  defp set_state(chat_id, state), do: ChatState.set_state(@state_table, chat_id, state)

  defp get_temp(chat_id, key), do: ChatState.get_temp(@temp_table, chat_id, key)

  defp put_temp(chat_id, key, value), do: ChatState.put_temp(@temp_table, chat_id, key, value)

  defp delete_temp(chat_id, key), do: ChatState.delete_temp(@temp_table, chat_id, key)

  defp clear_temp(chat_id), do: ChatState.clear_temp(@temp_table, chat_id)

  defp get_rfid_token do
    case SettingsStore.get() do
      %{rfid_telegram_token: token} when is_binary(token) and byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  # --- Telegram HTTP ---

  defp send_message(token, chat_id, text, reply_markup \\ nil) do
    Transport.send_message(token, chat_id, text, reply_markup, log_level: :debug)
  end

  defp edit_message(token, chat_id, message_id, text, reply_markup \\ nil) do
    Transport.edit_message(token, chat_id, message_id, text, reply_markup, log_level: :debug)
  end

  defp send_document(token, chat_id, filename, content, caption) do
    url = "https://api.telegram.org/bot#{token}/sendDocument"
    boundary = "----BotBoundary#{:erlang.unique_integer([:positive])}"

    parts =
      "--#{boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n#{chat_id}\r\n" <>
        "--#{boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"document\"; filename=\"#{filename}\"\r\n" <>
        "Content-Type: text/plain\r\n\r\n#{content}\r\n" <>
        if(caption,
          do:
            "--#{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n#{caption}\r\n",
          else: ""
        ) <>
        "--#{boundary}--\r\n"

    headers = [{"content-type", "multipart/form-data; boundary=#{boundary}"}]

    case Finch.build(:post, url, headers, parts)
         |> Finch.request(TitanBridgeFinch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: 200}} ->
        :ok

      {:error, err} ->
        Logger.debug("RFID bot sendDocument error: #{inspect(err)}")
        :error
    end
  end

  defp delete_message(token, chat_id, msg_id) do
    Transport.delete_message(token, chat_id, msg_id, log_level: :debug)
  end

  defp answer_callback(token, cb_id, text \\ nil) do
    Transport.answer_callback(token, cb_id, text, log_level: :debug)
  end

  defp setup_prompt(token, chat_id, text) do
    old_mid = get_temp(chat_id, "setup_msg_id")
    if old_mid, do: delete_message(token, chat_id, old_mid)
    new_mid = send_message(token, chat_id, text)
    put_temp(chat_id, "setup_msg_id", new_mid)
  end

  defp delete_setup_prompt(token, chat_id) do
    old_mid = get_temp(chat_id, "setup_msg_id")
    if old_mid, do: delete_message(token, chat_id, old_mid)
    delete_temp(chat_id, "setup_msg_id")
  end

  defp valid_api_credential?(value), do: SetupUtils.valid_api_credential?(value)

  defp normalize_erp_url(url), do: SetupUtils.normalize_erp_url(url)

  # --- Offset ---

  defp get_offset, do: ChatState.get_offset(@temp_table, 0)

  defp set_offset(update), do: ChatState.set_offset(@temp_table, update)

  # --- Config ---

  defp init_runtime_tables! do
    ensure_table!(@inflight_table)
    ensure_table!(@inflight_drafts_table)
    ensure_table!(@miss_table)
    ensure_table!(@submitted_table)
    ensure_table!(@submitted_drafts_table)
  end

  defp ensure_table!(name) do
    case :ets.whereis(name) do
      :undefined ->
        :ets.new(name, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _tid ->
        :ok
    end
  end

  defp mark_inflight(epc) do
    :ets.insert_new(@inflight_table, {epc, System.monotonic_time(:millisecond)})
  end

  defp inflight?(epc), do: :ets.member(@inflight_table, epc)

  defp clear_inflight(epc), do: :ets.delete(@inflight_table, epc)

  defp mark_draft_inflight(name) when is_binary(name) and name != "" do
    :ets.insert_new(@inflight_drafts_table, {name, System.monotonic_time(:millisecond)})
  end

  defp mark_draft_inflight(_), do: false

  defp draft_inflight?(name) when is_binary(name) and name != "" do
    :ets.member(@inflight_drafts_table, name)
  end

  defp draft_inflight?(_), do: false

  defp clear_draft_inflight(name) when is_binary(name) and name != "" do
    :ets.delete(@inflight_drafts_table, name)
  end

  defp clear_draft_inflight(_), do: :ok

  defp remember_miss(epc) do
    :ets.insert(@miss_table, {epc, System.monotonic_time(:millisecond)})
    :ok
  end

  defp clear_miss(epc), do: :ets.delete(@miss_table, epc)

  defp remember_submitted(epc) do
    :ets.insert(@submitted_table, {epc, System.monotonic_time(:millisecond)})
    :ok
  end

  defp remember_submitted_draft(name) when is_binary(name) and name != "" do
    :ets.insert(@submitted_drafts_table, {name, System.monotonic_time(:millisecond)})
    :ok
  end

  defp remember_submitted_draft(_), do: :ok

  defp recently_submitted?(epc) do
    now = System.monotonic_time(:millisecond)
    ttl = submitted_ttl_ms()

    case :ets.lookup(@submitted_table, epc) do
      [{^epc, ts}] ->
        if now - ts < ttl do
          true
        else
          :ets.delete(@submitted_table, epc)
          false
        end

      _ ->
        false
    end
  end

  defp recently_submitted_draft?(name) when is_binary(name) and name != "" do
    now = System.monotonic_time(:millisecond)
    ttl = submitted_draft_ttl_ms()

    case :ets.lookup(@submitted_drafts_table, name) do
      [{^name, ts}] ->
        if now - ts < ttl do
          true
        else
          :ets.delete(@submitted_drafts_table, name)
          false
        end

      _ ->
        false
    end
  end

  defp recently_submitted_draft?(_), do: false

  defp recently_missed?(epc) do
    now = System.monotonic_time(:millisecond)
    ttl = miss_ttl_ms()

    case :ets.lookup(@miss_table, epc) do
      [{^epc, ts}] ->
        if now - ts < ttl do
          true
        else
          :ets.delete(@miss_table, epc)
          false
        end

      _ ->
        false
    end
  end

  defp miss_ttl_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_MISS_TTL_MS") || "")) do
      {n, _} when n >= 0 and n <= 5_000 -> n
      _ -> @miss_ttl_default_ms
    end
  end

  defp submitted_ttl_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_SUBMITTED_TTL_MS") || "")) do
      {n, _} when n >= 0 and n <= 86_400_000 -> n
      _ -> 300_000
    end
  end

  defp submitted_draft_ttl_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_SUBMITTED_DRAFT_TTL_MS") || "")) do
      {n, _} when n >= 0 and n <= 86_400_000 -> n
      _ -> 21_600_000
    end
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp schedule_draft_refresh(ms) do
    Process.send_after(self(), :draft_refresh_tick, ms)
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, @poll_default_ms)
  end

  defp poll_timeout do
    Application.get_env(:titan_bridge, __MODULE__, [])
    |> Keyword.get(:poll_timeout_sec, @poll_timeout_default)
  end

  defp draft_refresh_interval_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_DRAFT_REFRESH_MS") || "")) do
      {n, _} when n >= 0 and n <= 3_600_000 -> n
      _ -> @draft_refresh_default_ms
    end
  end

  defp draft_sync_timeout_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_DRAFT_SYNC_TIMEOUT_MS") || "")) do
      {n, _} when n >= 5_000 and n <= 300_000 -> n
      _ -> @draft_sync_timeout_default_ms
    end
  end

  defp erp_fallback_timeout_ms do
    case Integer.parse(to_string(System.get_env("LCE_RFID_ERP_FALLBACK_TIMEOUT_MS") || "")) do
      {n, _} when n >= 500 and n <= 60_000 -> n
      _ -> 12_000
    end
  end

  defp refresh_draft_cache(full_refresh \\ true) do
    timeout = draft_sync_timeout_ms()

    case ErpSyncWorker.sync_now_blocking(full_refresh, timeout) do
      :ok ->
        {:ok, %{drafts: length(Cache.list_stock_drafts()), epcs: epc_mapping_size()}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp epc_mapping_size do
    case :ets.whereis(:lce_cache_epc_drafts) do
      :undefined -> 0
      _ -> :ets.info(:lce_cache_epc_drafts, :size) || 0
    end
  end

  # --- Inline cache (drafts) ---

  defp get_drafts_cache(chat_id) do
    now = System.system_time(:millisecond)

    case ChatState.get_temp(@temp_table, chat_id, :drafts) do
      {ts, drafts} when now - ts < @drafts_cache_ttl_ms ->
        {:ok, drafts}

      _ ->
        :miss
    end
  end

  defp put_drafts_cache(chat_id, drafts) when is_list(drafts) do
    ChatState.put_temp(
      @temp_table,
      chat_id,
      :drafts,
      {System.system_time(:millisecond), drafts}
    )
  end

  defp fetch_submit_drafts do
    case fetch_submit_drafts_detailed() do
      {:ok, drafts} -> drafts
      {:error, _} -> []
    end
  end

  defp fetch_submit_drafts_detailed do
    local = fetch_submit_drafts_local()

    if local != [] do
      {:ok, local}
    else
      fetch_submit_drafts_from_erp()
    end
  end

  defp fetch_submit_drafts_local do
    drafts = Cache.list_stock_drafts()
    index = epc_doc_index()

    drafts
    |> Enum.map(fn draft ->
      name = to_string(draft.name || "")
      mapped = Map.get(index, name, %{doc: %{}, epcs: []})
      mapped_doc = if is_map(mapped.doc), do: mapped.doc, else: %{}
      local_doc = if is_map(draft.data), do: draft.data, else: %{}
      doc = if map_size(mapped_doc) > 0, do: mapped_doc, else: local_doc

      summary = draft_from_doc(name, doc)
      epcs = Enum.uniq(summary.epcs ++ (mapped.epcs || []))
      %{summary | epcs: epcs}
    end)
    |> Enum.filter(fn d -> d.epcs != [] end)
  end

  defp fetch_submit_drafts_from_erp do
    case ErpClient.list_stock_drafts_modified(nil) do
      {:ok, rows} when is_list(rows) ->
        drafts =
          rows
          |> Enum.map(& &1["name"])
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Task.async_stream(&draft_summary/1,
            ordered: false,
            max_concurrency: 6,
            timeout: 20_000
          )
          |> Enum.reduce([], fn
            {:ok, draft}, acc -> [draft | acc]
            _, acc -> acc
          end)
          |> Enum.reverse()
          |> Enum.filter(fn d -> d.epcs != [] end)

        {:ok, drafts}

      {:error, _} = err ->
        err

      _ ->
        {:ok, []}
    end
  end

  defp epc_doc_index do
    case :ets.whereis(:lce_cache_epc_drafts) do
      :undefined ->
        %{}

      _ ->
        :ets.tab2list(:lce_cache_epc_drafts)
        |> Enum.reduce(%{}, fn
          {epc, %{name: name, doc: doc}}, acc when is_binary(name) ->
            prev = Map.get(acc, name, %{doc: %{}, epcs: []})

            merged_doc =
              if map_size(prev.doc || %{}) > 0 do
                prev.doc
              else
                if is_map(doc), do: doc, else: %{}
              end

            merged_epcs =
              [to_string(epc || "") | prev.epcs || []]
              |> Enum.filter(&(&1 != ""))

            Map.put(acc, name, %{doc: merged_doc, epcs: merged_epcs})

          _, acc ->
            acc
        end)
        |> Map.new(fn {name, info} ->
          {name, %{doc: info.doc || %{}, epcs: Enum.uniq(info.epcs || [])}}
        end)
    end
  end

  defp draft_summary(name) when is_binary(name) do
    case ErpClient.get_doc("Stock Entry", name) do
      {:ok, doc} when is_map(doc) ->
        draft_from_doc(name, doc)

      _ ->
        %{name: name, items: [], epcs: []}
    end
  end

  defp draft_from_doc(name, doc) when is_map(doc) do
    items = doc["items"] || doc[:items] || []

    epcs =
      items
      |> Enum.flat_map(fn item ->
        barcode = String.trim(item["barcode"] || item[:barcode] || "")
        batch = String.trim(item["batch_no"] || item[:batch_no] || "")
        serial = String.trim(item["serial_no"] || item[:serial_no] || "")

        serials =
          if serial != "" do
            serial
            |> String.split(~r/[\s,]+/, trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.filter(&(&1 != ""))
          else
            []
          end

        Enum.filter([barcode, batch], &(&1 != "")) ++ serials
      end)

    epcs =
      case extract_epc_from_remarks(doc["remarks"] || doc[:remarks]) do
        nil -> epcs
        remark_epc -> [remark_epc | epcs]
      end

    %{
      name: doc["name"] || doc[:name] || name,
      items:
        Enum.map(items, fn item ->
          %{
            item_code: item["item_code"] || item[:item_code],
            qty: item["qty"] || item[:qty],
            serial_no: item["serial_no"] || item[:serial_no],
            batch_no: item["batch_no"] || item[:batch_no],
            barcode: item["barcode"] || item[:barcode],
            s_warehouse: item["s_warehouse"] || item[:s_warehouse]
          }
        end),
      epcs: Enum.uniq(epcs)
    }
  end

  defp draft_from_doc(name, _doc), do: %{name: name, items: [], epcs: []}

  defp extract_epc_from_remarks(remarks) when is_binary(remarks) do
    text =
      remarks
      |> String.upcase()
      |> String.replace(~r/[^0-9A-F]+/, " ")

    case Regex.run(~r/\b([0-9A-F]{12,})\b/, text) do
      [_, epc] -> epc
      _ -> nil
    end
  end

  defp extract_epc_from_remarks(_), do: nil
end
