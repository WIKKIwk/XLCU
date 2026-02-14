defmodule TitanBridge.ErpSyncWorker do
  @moduledoc """
  Periodic sync worker — keeps local cache in sync with ERPNext.

  Polls ERPNext every 10s (configurable via LCE_SYNC_INTERVAL_MS).
  Incremental sync by default; full refresh every 6th cycle.

  Sync targets: Items, Warehouses, Bins (stock levels), Stock Drafts.
  Each has a "last modified" watermark stored in lce_sync_state table.

  Also handles incoming ERP webhooks (e.g. item updated, draft submitted).
  On each sync cycle, updates ETS cache and broadcasts via Realtime PubSub.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias TitanBridge.{Cache, ErpClient, Realtime, Repo, SyncState}
  alias TitanBridge.Cache.{Item, Warehouse, Bin, StockDraft}
  alias TitanBridge.Telegram.RfidBot

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def sync_now(full_refresh \\ true) do
    GenServer.cast(__MODULE__, {:sync_now, full_refresh})
  end

  def sync_now_blocking(full_refresh \\ true, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:sync_now_blocking, full_refresh}, timeout)
  end

  def handle_webhook(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:webhook, payload})
  end

  @impl true
  def init(_state) do
    Cache.warmup()
    schedule_poll(0)
    {:ok, %{poll_count: 0}}
  end

  @impl true
  def handle_cast({:webhook, payload}, state) do
    process_webhook(payload)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_now, full_refresh}, state) do
    if configured?() do
      sync_all(full_refresh)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:sync_now_blocking, full_refresh}, _from, state) do
    result =
      if configured?() do
        sync_all(full_refresh)
      else
        {:error, "ERP config missing"}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    next_state =
      if configured?() do
        poll_count = state.poll_count + 1
        full_refresh = full_refresh?(poll_count)
        sync_all(full_refresh)
        %{state | poll_count: poll_count}
      else
        state
      end

    schedule_poll(poll_interval())
    {:noreply, next_state}
  end

  defp poll_interval do
    Application.get_env(:titan_bridge, __MODULE__)[:poll_interval_ms] || 10_000
  end

  defp full_refresh_every do
    Application.get_env(:titan_bridge, __MODULE__)[:full_refresh_every] || 6
  end

  defp full_refresh?(count) do
    n = full_refresh_every()
    n > 0 and rem(count, n) == 0
  end

  defp schedule_poll(ms) do
    Process.send_after(self(), :poll, ms)
  end

  defp configured? do
    cfg = ErpClient.get_config()

    is_binary(cfg[:erp_url]) and String.trim(cfg[:erp_url]) != "" and
      is_binary(cfg[:erp_token]) and String.trim(cfg[:erp_token]) != ""
  end

  defp sync_all(full_refresh) do
    sync_items()
    sync_warehouses()
    sync_bins()
    sync_stock_drafts(full_refresh)
  end

  defp sync_items do
    since = SyncState.get("items_modified")
    rows = fetch_rows(&ErpClient.list_items_modified/1, since)
    update_items(rows)
    maybe_put_sync_state("items_modified", rows)
  end

  defp sync_warehouses do
    since = SyncState.get("warehouses_modified")
    rows = fetch_rows(&ErpClient.list_warehouses_modified/1, since)
    update_warehouses(rows)
    maybe_put_sync_state("warehouses_modified", rows)
  end

  defp sync_bins do
    since = SyncState.get("bins_modified")
    rows = fetch_rows(&ErpClient.list_bins_modified/1, since)
    update_bins(rows)
    maybe_put_sync_state("bins_modified", rows)
  end

  defp sync_stock_drafts(full_refresh) do
    # EPC-only payload returns compact snapshot for mapping. To avoid dropping
    # unchanged EPCs, always request full snapshot in EPC-only mode.
    since =
      if full_refresh or use_epc_only_payload?(),
        do: nil,
        else: SyncState.get("stock_drafts_modified")

    case fetch_stock_draft_rows(since) do
      {:epc_only, epcs, max_modified, draft_count} ->
        if full_refresh, do: clear_stock_drafts()
        put_epc_only_mapping(epcs)
        if is_binary(max_modified) and String.trim(max_modified) != "", do: SyncState.put("stock_drafts_modified", max_modified)
        %{drafts: to_int_or_default(draft_count, 0), epcs: length(epcs), source: :epc_only}

      {:rows, rows} ->
        cond do
          rows == [] and full_refresh ->
            clear_stock_drafts()

          true ->
            update_stock_drafts(rows, full_refresh)
            maybe_put_sync_state("stock_drafts_modified", rows)
        end

        # EPC → draft mapping yangilash (lokal cache dan)
        build_epc_draft_mapping()
        %{drafts: count_stock_drafts(), epcs: epc_mapping_size(), source: :rows}
    end
  end

  defp fetch_stock_draft_rows(since) do
    if use_fast_drafts_api?() do
      case ErpClient.get_open_stock_entry_drafts_fast(since,
             limit: fast_drafts_limit(),
             include_items: false,
             only_with_epc: true,
             compact: true,
             epc_only: use_epc_only_payload?()
           ) do
        {:ok, payload} ->
          if payload["epc_only"] in [true, "true", 1, "1"] do
            epcs =
              (payload["epcs"] || [])
              |> Enum.map(&to_string/1)
              |> Enum.map(&String.trim/1)
              |> Enum.filter(&(&1 != ""))
              |> Enum.uniq()

            draft_count = payload["count_drafts"] || payload["draft_count"]
            draft_count_int = to_int_or_default(draft_count, 0)

            Logger.info(
              "[FAST_DRAFTS] ERP epc_only loaded #{length(epcs)} epcs, #{draft_count_int} drafts (since=#{inspect(since)})"
            )

            {:epc_only, epcs, payload["max_modified"], draft_count_int}
          else
            drafts = payload["drafts"] || []

            rows =
              drafts
              |> Enum.map(&fast_draft_to_row/1)
              |> Enum.filter(&is_binary(&1["name"]))

            Logger.info(
              "[FAST_DRAFTS] ERP method loaded #{length(rows)} drafts (since=#{inspect(since)})"
            )

            {:rows, rows}
          end

        {:error, reason} ->
          Logger.warning(
            "[FAST_DRAFTS] method failed, fallback to Stock Entry list: #{inspect(reason)}"
          )

          {:rows, fetch_rows(&ErpClient.list_stock_drafts_modified/1, since)}
      end
    else
      {:rows, fetch_rows(&ErpClient.list_stock_drafts_modified/1, since)}
    end
  end

  defp fast_draft_to_row(draft) when is_map(draft) do
    raw_items = draft["items"] || []
    epcs = draft["epcs"] || []

    items =
      cond do
        is_list(raw_items) and raw_items != [] ->
          raw_items
          |> Enum.map(fn item ->
            %{
              "item_code" => item["item_code"],
              "qty" => item["qty"],
              "s_warehouse" => item["s_warehouse"],
              "t_warehouse" => item["t_warehouse"],
              "barcode" => item["barcode"] || "",
              "batch_no" => item["batch_no"] || "",
              "serial_no" => item["serial_no"] || ""
            }
          end)

        is_list(epcs) and epcs != [] ->
          epcs
          |> Enum.map(fn epc ->
            %{
              "item_code" => nil,
              "qty" => 1,
              "s_warehouse" => nil,
              "t_warehouse" => nil,
              "barcode" => epc,
              "batch_no" => "",
              "serial_no" => ""
            }
          end)

        true ->
          []
      end

    %{
      "name" => draft["name"],
      "docstatus" => 0,
      "purpose" => draft["purpose"],
      "posting_date" => draft["posting_date"],
      "posting_time" => draft["posting_time"],
      "from_warehouse" => draft["from_warehouse"],
      "to_warehouse" => draft["to_warehouse"],
      "modified" => draft["modified"],
      "items" => items
    }
  end

  defp fast_draft_to_row(_), do: %{}

  defp use_fast_drafts_api? do
    case String.downcase(to_string(System.get_env("LCE_ERP_FAST_DRAFT_API") || "1")) do
      "0" -> false
      "false" -> false
      "no" -> false
      _ -> true
    end
  end

  defp fast_drafts_limit do
    case Integer.parse(to_string(System.get_env("LCE_ERP_FAST_DRAFT_LIMIT") || "")) do
      {n, _} when n >= 100 and n <= 50_000 -> n
      _ -> 5000
    end
  end

  defp use_epc_only_payload? do
    case String.downcase(to_string(System.get_env("LCE_ERP_FAST_DRAFT_EPC_ONLY") || "1")) do
      "0" -> false
      "false" -> false
      "no" -> false
      _ -> true
    end
  end

  defp put_epc_only_mapping(epcs) when is_list(epcs) do
    mappings =
      epcs
      |> Enum.map(&normalize_epc/1)
      |> Enum.filter(&(&1 != ""))
      |> Enum.uniq()
      |> Enum.map(fn epc ->
        {epc,
         %{
           name: "EPC:" <> epc,
           doc: %{"name" => "EPC:" <> epc, "docstatus" => 0, "items" => []}
         }}
      end)

    Cache.put_epc_draft_mapping(mappings)
    Logger.info("[FAST_DRAFTS] EPC-only mapping updated: #{length(mappings)} epcs")
  end

  defp count_stock_drafts do
    Cache.list_stock_drafts()
    |> length()
  end

  defp epc_mapping_size do
    case :ets.whereis(:lce_cache_epc_drafts) do
      :undefined -> 0
      _ -> :ets.info(:lce_cache_epc_drafts, :size) || 0
    end
  end

  defp to_int_or_default(nil, default), do: default

  defp to_int_or_default(value, _default) when is_integer(value), do: value

  defp to_int_or_default(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int_or_default(_value, default), do: default

  defp fetch_rows(fun, since) do
    case fun.(since) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        Logger.warning("ERP sync failed: #{inspect(reason)}")
        []
    end
  end

  defp maybe_put_sync_state(_key, []), do: :ok

  defp maybe_put_sync_state(key, rows) do
    case max_modified(rows) do
      nil -> :ok
      value -> SyncState.put(key, value)
    end
  end

  defp update_items([]), do: :ok

  defp update_items(rows) do
    now = now()
    maps = Enum.map(rows, &item_map(&1, now))

    {_count, _} =
      Repo.insert_all(Item, maps,
        on_conflict: {:replace, [:item_name, :stock_uom, :disabled, :modified, :updated_at]},
        conflict_target: :name
      )

    Cache.put_items(maps)
    broadcast(:items, length(maps))
  end

  defp update_warehouses([]), do: :ok

  defp update_warehouses(rows) do
    now = now()
    maps = Enum.map(rows, &warehouse_map(&1, now))

    {_count, _} =
      Repo.insert_all(Warehouse, maps,
        on_conflict: {:replace, [:warehouse_name, :is_group, :disabled, :modified, :updated_at]},
        conflict_target: :name
      )

    Cache.put_warehouses(maps)
    broadcast(:warehouses, length(maps))
  end

  defp update_bins([]), do: :ok

  defp update_bins(rows) do
    now = now()
    maps = Enum.map(rows, &bin_map(&1, now))

    {_count, _} =
      Repo.insert_all(Bin, maps,
        on_conflict: {:replace, [:actual_qty, :modified, :updated_at]},
        conflict_target: [:item_code, :warehouse]
      )

    Cache.put_bins(maps)
    broadcast(:bins, length(maps))
  end

  defp update_stock_drafts([], _full_refresh), do: :ok

  defp update_stock_drafts(rows, full_refresh) do
    now = now()
    maps = Enum.map(rows, &stock_draft_map(&1, now))

    {_count, _} =
      Repo.insert_all(StockDraft, maps,
        on_conflict:
          {:replace,
           [
             :docstatus,
             :purpose,
             :posting_date,
             :posting_time,
             :from_warehouse,
             :to_warehouse,
             :modified,
             :data,
             :updated_at
           ]},
        conflict_target: :name
      )

    if full_refresh do
      names = Enum.map(maps, & &1.name)
      from(d in StockDraft, where: d.name not in ^names) |> Repo.delete_all()
      Cache.replace_stock_drafts(maps)
    else
      Cache.put_stock_drafts(maps)
    end

    broadcast(:stock_drafts, length(maps))
  end

  # Draftlardan EPC → draft mapping yaratish
  # Har bir draft uchun to'liq doc (items + serial_no) olib kelinadi
  defp build_epc_draft_mapping do
    drafts = Cache.list_stock_drafts()
    Logger.info("[EPC_MAP] Mapping qurilmoqda: #{length(drafts)} ta draft")

    {fetched_count, cached_count} =
      drafts
      |> Enum.reduce({0, 0}, fn draft, {f, c} ->
        data = draft.data || %{}
        if is_list(data["items"]) and data["items"] != [], do: {f, c + 1}, else: {f + 1, c}
      end)

    Logger.info("[EPC_MAP] items mavjud: #{cached_count}, get_doc kerak: #{fetched_count}")

    mappings =
      drafts
      |> Enum.flat_map(fn draft ->
        doc = fetch_full_doc(draft)
        items = doc["items"] || []

        remark_epc = extract_epc_from_remarks(doc["remarks"])

        candidates =
          if(remark_epc, do: [remark_epc], else: []) ++
            Enum.flat_map(items, fn item ->
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

              Enum.filter([barcode, batch], &(&1 != "")) ++ serials
            end)

        candidates
        |> Enum.map(&normalize_epc/1)
        |> Enum.filter(&(&1 != ""))
        |> Enum.uniq()
        |> Enum.map(fn epc -> {epc, %{name: draft.name, doc: doc}} end)
      end)

    Cache.put_epc_draft_mapping(mappings)
    epc_list = Enum.map(mappings, fn {epc, _} -> epc end)
    Logger.info("[EPC_MAP] Tayyor: #{length(mappings)} ta EPC mapping. Namuna: #{inspect(Enum.take(epc_list, 5))}")
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

  defp fetch_full_doc(draft) do
    # Avval data fieldidan tekshiramiz — items bormi?
    data = draft.data || %{}

    if is_list(data["items"]) and data["items"] != [] do
      data
    else
      Logger.debug("[EPC_MAP] get_doc: #{draft.name}...")
      case ErpClient.get_doc("Stock Entry", draft.name) do
        {:ok, doc} ->
          items = doc["items"] || []
          barcodes = Enum.map(items, fn i -> i["barcode"] end) |> Enum.filter(&is_binary/1)
          Logger.info("[EPC_MAP] get_doc OK: #{draft.name} items=#{length(items)} barcodes=#{inspect(barcodes)}")

          now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

          Repo.update_all(
            from(d in StockDraft, where: d.name == ^draft.name),
            set: [data: doc, updated_at: now]
          )

          # ETS keshni ham yangilaymiz — keyingi siklda qayta so'rov ketmasligi uchun
          updated = %{draft | data: doc, updated_at: now}
          :ets.insert(:lce_cache_stock_drafts, {draft.name, updated})

          doc

        {:error, reason} ->
          Logger.warning("[EPC_MAP] get_doc XATO: #{draft.name} -> #{inspect(reason)}")
          data
      end
    end
  end

  defp normalize_epc(raw) do
    raw |> String.trim() |> String.upcase() |> String.replace(~r/[^0-9A-F]/, "")
  end

  defp process_webhook(payload) do
    doc = payload["doc"] || payload["data"] || %{}
    doctype = payload["doctype"] || doc["doctype"]
    name = payload["name"] || doc["name"]
    event = payload["event"] || payload["method"] || payload["action"] || "unknown"

    case doctype do
      "Item" ->
        with {:ok, row} <- resolve_doc(doc, "Item", name) do
          update_items([row])
        end

      "Warehouse" ->
        with {:ok, row} <- resolve_doc(doc, "Warehouse", name) do
          update_warehouses([row])
        end

      "Bin" ->
        with {:ok, row} <- resolve_doc(doc, "Bin", name) do
          update_bins([row])
        end

      "Stock Entry" ->
        if use_epc_only_payload?() do
          _ = sync_stock_drafts(false)
          maybe_notify_new_draft(name, event)
          RfidBot.replay_recent_misses()
          :ok
        else
          with {:ok, row} <- resolve_doc(doc, "Stock Entry", name) do
            is_open = to_int(row["docstatus"]) == 0

            if is_open do
              update_stock_drafts([row], false)
              maybe_notify_new_draft(row["name"] || name, event)
            else
              delete_stock_draft(row["name"])
            end

            # Keep EPC→draft mapping in sync for webhook-driven updates.
            build_epc_draft_mapping()

            if is_open do
              RfidBot.replay_recent_misses()
            end
          end
        end

      _ ->
        :ok
    end
  end

  defp maybe_notify_new_draft(name, event) do
    try do
      RfidBot.notify_draft_event(to_string(name || ""), event)
    rescue
      _ -> :ok
    end
  end

  defp resolve_doc(doc, doctype, name) do
    if map_size(doc) > 0 do
      {:ok, doc}
    else
      case ErpClient.get_doc(doctype, name) do
        {:ok, row} ->
          {:ok, row}

        {:error, reason} ->
          Logger.warning("ERP webhook fetch failed: #{doctype} #{name} #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp delete_stock_draft(nil), do: :ok

  defp delete_stock_draft(name) do
    Repo.delete_all(from(d in StockDraft, where: d.name == ^name))
    Cache.delete_stock_draft(name)
    broadcast(:stock_drafts, 1)
  end

  defp clear_stock_drafts do
    Repo.delete_all(StockDraft)
    Cache.replace_stock_drafts([])
    broadcast(:stock_drafts, 1)
  end

  defp broadcast(_entity, count) when count <= 0, do: :ok

  defp broadcast(entity, _count) do
    payload = %{
      type: "cache_updated",
      entity: entity,
      versions: %{
        items: Cache.version(:items),
        warehouses: Cache.version(:warehouses),
        bins: Cache.version(:bins),
        stock_drafts: Cache.version(:stock_drafts)
      }
    }

    Realtime.broadcast(payload)
  end

  defp item_map(row, now) do
    %{
      name: row["name"],
      item_name: row["item_name"],
      stock_uom: row["stock_uom"],
      disabled: to_bool(row["disabled"]),
      modified: row["modified"],
      inserted_at: now,
      updated_at: now
    }
  end

  defp warehouse_map(row, now) do
    %{
      name: row["name"],
      warehouse_name: row["warehouse_name"],
      is_group: to_bool(row["is_group"]),
      disabled: to_bool(row["disabled"]),
      modified: row["modified"],
      inserted_at: now,
      updated_at: now
    }
  end

  defp bin_map(row, now) do
    %{
      item_code: row["item_code"],
      warehouse: row["warehouse"],
      actual_qty: to_float(row["actual_qty"]),
      modified: row["modified"],
      inserted_at: now,
      updated_at: now
    }
  end

  defp stock_draft_map(row, now) do
    %{
      name: row["name"],
      docstatus: to_int(row["docstatus"]),
      purpose: row["purpose"],
      posting_date: row["posting_date"],
      posting_time: row["posting_time"],
      from_warehouse: row["from_warehouse"],
      to_warehouse: row["to_warehouse"],
      modified: row["modified"],
      data: row,
      inserted_at: now,
      updated_at: now
    }
  end

  defp max_modified(rows) do
    rows
    |> Enum.map(& &1["modified"])
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      list -> Enum.max(list)
    end
  end

  defp now do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp to_bool(val) when val in [true, 1, "1", "true", "yes", "on"], do: true
  defp to_bool(_), do: false

  defp to_int(val) when is_integer(val), do: val

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_float(val) when is_float(val), do: val
  defp to_float(val) when is_integer(val), do: val * 1.0

  defp to_float(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> n
      _ -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
