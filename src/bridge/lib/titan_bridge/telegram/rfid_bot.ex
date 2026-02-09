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

  alias TitanBridge.{SettingsStore, ErpClient, RfidListener, EpcRegistry, Cache}
  alias TitanBridge.Telegram.{ChatState, SetupUtils, Transport}

  @state_table :rfid_tg_state
  @temp_table :rfid_tg_temp
  @poll_default_ms 1200
  @poll_timeout_default 25
  @drafts_cache_ttl_ms 60_000

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    ChatState.init_tables!(@state_table, @temp_table)
    schedule_poll(poll_interval())
    {:ok, %{}}
  end

  # --- Telegram Polling ---

  @impl true
  def handle_info(:poll, state) do
    case SettingsStore.get() do
      %{rfid_telegram_token: token} when is_binary(token) and byte_size(token) > 0 ->
        poll_updates(token)

      _ ->
        :ok
    end

    schedule_poll(poll_interval())
    {:noreply, state}
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
    # "/command@botname" → "/command"
    cmd = text |> String.trim() |> String.split("@") |> hd() |> String.downcase()
    user = msg["from"] || %{}
    user_id =
      case user do
        %{"id" => id} when is_integer(id) -> id
        _ -> nil
      end

    cond do
      cmd == "/start" ->
        delete_message(token, chat_id, msg_id)
        set_state(chat_id, "awaiting_erp_url")
        setup_prompt(token, chat_id, "ERP manzilini kiriting:")

      cmd == "/submit" ->
        delete_message(token, chat_id, msg_id)
        handle_submit_prompt(token, chat_id, user_id)

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
    user_id =
      case cb do
        %{"from" => %{"id" => id}} when is_integer(id) -> id
        _ -> nil
      end

    case data do
      "retry_scan" ->
        answer_callback(token, cb_id, "Tekshirilmoqda...")
        delete_message(token, chat_id, cb["message"]["message_id"])
        handle_scan(token, chat_id)

      "retry_submit" ->
        answer_callback(token, cb_id, "Tekshirilmoqda...")
        delete_message(token, chat_id, cb["message"]["message_id"])
        handle_submit_prompt(token, chat_id, user_id)

      _ ->
        answer_callback(token, cb_id)
    end
  end

  defp handle_update(_token, _update), do: :ok

  # --- Setup Wizard (same as Zebra bot) ---

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
    if get_state(chat_id) == "scanning" do
      send_message(token, chat_id, "Allaqachon skaner rejimida. /stop bilan to'xtating.")
    else
      case ErpClient.ping() do
        {:ok, _} ->
          do_scan(token, chat_id)

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
  end

  # --- /submit: draft tanlash (inline menu) + submit ---

  defp handle_submit_prompt(token, chat_id, user_id \\ nil) do
    case ErpClient.ping() do
      {:ok, _} ->
        put_temp(chat_id, "inline_mode", "draft_submit")
        # Force refresh so newly created drafts show up immediately.
        # Inline-query cache is keyed by Telegram *user id*, while flow messages are keyed by chat id.
        clear_drafts_cache(chat_id, user_id)

        keyboard = %{
          "inline_keyboard" => [
            [%{"text" => "Draft tanlash", "switch_inline_query_current_chat" => "draft "}]
          ]
        }

        text = "Draftlarni tanlang: pastdagi tugmani bosing."
        flow_mid = get_temp(chat_id, "submit_flow_msg_id")

        mid =
          if is_integer(flow_mid) do
            _ = edit_message(token, chat_id, flow_mid, text, keyboard)
            flow_mid
          else
            send_message(token, chat_id, text, keyboard)
          end

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

  defp handle_submit_selection(token, chat_id, user_id, name) do
    name = String.trim(name || "")

    if name == "" do
      send_message(token, chat_id, "Draft tanlanmadi. /submit bilan qayta urinib ko'ring.")
    else
      keyboard = %{
        "inline_keyboard" => [
          [%{"text" => "Yana draft tanlash", "switch_inline_query_current_chat" => "draft "}]
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
      RfidListener.unsubscribe(self())
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
    case ErpClient.list_drafts_with_epc() do
      {:ok, drafts} when drafts != [] ->
        lines =
          drafts
          |> Enum.take(20)
          |> Enum.map(fn d ->
            items =
              Enum.map(d.items, fn i ->
                epc = i.batch_no || i.serial_no
                sn = if epc, do: " [#{String.slice(epc, 0, 12)}...]", else: ""
                "#{i.item_code}: #{i.qty}#{sn}"
              end)
              |> Enum.join(", ")

            "#{d.name} — #{items}"
          end)
          |> Enum.join("\n")

        send_message(token, chat_id, "Draft'lar (#{length(drafts)}):\n\n#{lines}")

      {:ok, []} ->
        send_message(token, chat_id, "EPC li draft topilmadi.")

      {:error, reason} ->
        send_message(token, chat_id, "Xato: #{inspect(reason)}")
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
    # Dublikat filtr: soniyasiga 20+ marta kelishi mumkin
    # Faqat yangi EPC lar PostgreSQL ga yoziladi va ERPNext dan qidiriladi
    case EpcRegistry.register_once(epc) do
      {:ok, :new} ->
        Logger.info("RFID yangi EPC: #{epc}")
        search_and_submit(epc)

      {:ok, :exists} ->
        # Allaqachon ko'rilgan EPC — skip
        :ok
    end
  end

  defp search_and_submit(epc) do
    token = get_rfid_token()
    chats = scanning_chats()

    if chats == [] or is_nil(token) do
      :ok
    else
      # 1) Avval lokal cache dan qidirish (ETS — bir zumda)
      # 2) Topilmasa — ERPNext dan qidirish (fallback)
      case find_draft_by_epc(epc) do
        {:ok, draft_info} ->
          do_submit(draft_info.name, draft_info.doc, epc, token, chats)

        :not_found ->
          :ok

        {:error, reason} ->
          Logger.warning("RFID EPC qidirish xato: #{inspect(reason)}")
          stop_scanning_erp_down(token, chats, reason)
      end
    end
  end

  # Gibrid qidirish: lokal cache → ERPNext fallback
  defp find_draft_by_epc(epc) do
    case Cache.find_draft_by_epc(epc) do
      {:ok, draft_info} ->
        # Lokal cache dan topildi — tarmoqsiz, bir zumda
        Logger.debug("RFID EPC lokal cache dan topildi: #{epc}")
        {:ok, draft_info}

      :not_found ->
        # Lokal cache da yo'q — ERPNext dan tekshiramiz (yangi draft bo'lishi mumkin)
        Logger.debug("RFID EPC lokal cache da yo'q, ERPNext dan qidirilmoqda: #{epc}")

        case ErpClient.find_draft_by_serial_no(epc) do
          {:ok, doc} ->
            {:ok, %{name: doc["name"], doc: doc}}

          :not_found ->
            :not_found

          {:error, _} = err ->
            err
        end
    end
  end

  defp do_submit(name, doc, epc, token, chats) do
    case ErpClient.submit_stock_entry(name) do
      {:ok, _} ->
        EpcRegistry.mark_submitted(epc)
        # Lokal cache dan olib tashlaymiz — qayta submit bo'lmasin
        Cache.delete_epc_mapping(epc)
        Logger.info("RFID auto-submit: #{name} (EPC: #{epc})")

        items = (doc || %{})["items"] || []

        items_text =
          items
          |> Enum.map(fn i -> "#{i["item_code"]}: #{i["qty"]}" end)
          |> Enum.join(", ")

        Enum.each(chats, fn chat_id ->
          old_count = get_temp(chat_id, "submitted_count") || 0
          put_temp(chat_id, "submitted_count", old_count + 1)

          send_message(
            token,
            chat_id,
            "#{name} submitted!\n#{items_text}\n" <>
              "EPC: #{String.slice(epc, 0, 16)}..."
          )
        end)

      {:error, reason} ->
        Logger.warning("RFID submit xato: #{name} — #{inspect(reason)}")
        stop_scanning_erp_down(token, chats, reason)
    end
  end

  defp stop_scanning_erp_down(token, chats, reason \\ nil) do
    RfidListener.unsubscribe(self())
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
          (if reason_text, do: "Sabab: #{reason_text}\n", else: "") <>
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

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__, [])
    |> Keyword.get(:poll_interval_ms, @poll_default_ms)
  end

  defp poll_timeout do
    Application.get_env(:titan_bridge, __MODULE__, [])
    |> Keyword.get(:poll_timeout_sec, @poll_timeout_default)
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
    case ErpClient.list_stock_drafts_modified(nil) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.map(& &1["name"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.map(&draft_summary/1)

      _ ->
        []
    end
  end

  defp draft_summary(name) when is_binary(name) do
    case ErpClient.get_doc("Stock Entry", name) do
      {:ok, doc} when is_map(doc) ->
        items = doc["items"] || []

        epcs =
          items
          |> Enum.flat_map(fn item ->
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
            Enum.filter([barcode, batch], &(&1 != "")) ++ serials
          end)

        epcs =
          case extract_epc_from_remarks(doc["remarks"]) do
            nil -> epcs
            remark_epc -> [remark_epc | epcs]
          end

        %{
          name: doc["name"] || name,
          items:
            Enum.map(items, fn item ->
              %{
                item_code: item["item_code"],
                qty: item["qty"],
                serial_no: item["serial_no"],
                batch_no: item["batch_no"],
                barcode: item["barcode"],
                s_warehouse: item["s_warehouse"]
              }
            end),
          epcs: Enum.uniq(epcs)
        }

      _ ->
        %{name: name, items: [], epcs: []}
    end
  end

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
