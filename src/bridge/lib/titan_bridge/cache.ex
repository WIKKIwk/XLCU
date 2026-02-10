defmodule TitanBridge.Cache do
  @moduledoc """
  In-memory ETS cache for ERPNext data — fast lookups without DB roundtrip.

  Four tables (populated by ErpSyncWorker):
    :lce_cache_items        — products (name, stock_uom, disabled)
    :lce_cache_warehouses   — warehouses (name, is_group, disabled)
    :lce_cache_bins         — stock levels per item/warehouse
    :lce_cache_stock_drafts — pending Stock Entry drafts

  Each table has a version counter. WebSocket clients compare versions
  to detect changes. Also persisted to PostgreSQL for restart recovery.
  """
  alias TitanBridge.Repo
  alias TitanBridge.Cache.{Item, Warehouse, Bin, StockDraft}

  @items_table :lce_cache_items
  @warehouses_table :lce_cache_warehouses
  @bins_table :lce_cache_bins
  @drafts_table :lce_cache_stock_drafts
  @epc_drafts_table :lce_cache_epc_drafts
  @meta_table :lce_cache_meta

  def ensure_tables do
    create_table(@items_table)
    create_table(@warehouses_table)
    create_table(@bins_table)
    create_table(@drafts_table)
    create_table(@epc_drafts_table)
    create_table(@meta_table)
    :ok
  end

  def warmup do
    ensure_tables()
    load_items()
    load_warehouses()
    load_bins()
    load_stock_drafts()
    :ok
  end

  @doc """
  Deletes ALL cached ERP records (DB + ETS).

  Use this when ERP URL/token changes to avoid showing stale products/warehouses/bins.
  """
  def purge_all do
    # DB
    _ = Repo.delete_all(Item)
    _ = Repo.delete_all(Warehouse)
    _ = Repo.delete_all(Bin)
    _ = Repo.delete_all(StockDraft)

    # ETS
    ensure_tables()
    :ets.delete_all_objects(@items_table)
    :ets.delete_all_objects(@warehouses_table)
    :ets.delete_all_objects(@bins_table)
    :ets.delete_all_objects(@drafts_table)
    :ets.delete_all_objects(@epc_drafts_table)
    :ets.delete_all_objects(@meta_table)
    :ok
  end

  def version(entity) do
    case :ets.lookup(@meta_table, {entity, :version}) do
      [{{^entity, :version}, v}] -> v
      _ -> 0
    end
  end

  def bump_version(entity, count) when is_integer(count) do
    if count > 0 do
      :ets.update_counter(@meta_table, {entity, :version}, {2, 1}, {{entity, :version}, 0})
    end
  end

  def put_items(items) when is_list(items) do
    ensure_tables()
    Enum.each(items, fn item ->
      :ets.insert(@items_table, {item.name, item})
    end)
    bump_version(:items, length(items))
  end

  def put_warehouses(warehouses) when is_list(warehouses) do
    ensure_tables()
    Enum.each(warehouses, fn wh ->
      :ets.insert(@warehouses_table, {wh.name, wh})
    end)
    bump_version(:warehouses, length(warehouses))
  end

  def put_bins(bins) when is_list(bins) do
    ensure_tables()
    Enum.each(bins, fn bin ->
      key = {bin.item_code, bin.warehouse}
      :ets.insert(@bins_table, {key, bin})
    end)
    bump_version(:bins, length(bins))
  end

  def put_stock_drafts(drafts) when is_list(drafts) do
    ensure_tables()
    Enum.each(drafts, fn draft ->
      :ets.insert(@drafts_table, {draft.name, draft})
    end)
    bump_version(:stock_drafts, length(drafts))
  end

  def replace_stock_drafts(drafts) when is_list(drafts) do
    ensure_tables()
    :ets.delete_all_objects(@drafts_table)
    Enum.each(drafts, fn draft ->
      :ets.insert(@drafts_table, {draft.name, draft})
    end)
    bump_version(:stock_drafts, 1)
  end

  def delete_stock_draft(name) when is_binary(name) do
    ensure_tables()
    :ets.delete(@drafts_table, name)
    bump_version(:stock_drafts, 1)
  end

  def get_item(item_code) when is_binary(item_code) do
    ensure_tables()
    case :ets.lookup(@items_table, item_code) do
      [{^item_code, item}] -> item
      _ -> nil
    end
  end

  def list_items do
    ensure_tables()
    case :ets.tab2list(@items_table) do
      [] -> load_items()
      entries -> Enum.map(entries, fn {_k, v} -> v end)
    end
  end

  def list_warehouses do
    ensure_tables()
    case :ets.tab2list(@warehouses_table) do
      [] -> load_warehouses()
      entries -> Enum.map(entries, fn {_k, v} -> v end)
    end
  end

  def list_bins do
    ensure_tables()
    case :ets.tab2list(@bins_table) do
      [] -> load_bins()
      entries -> Enum.map(entries, fn {_k, v} -> v end)
    end
  end

  def list_stock_drafts do
    ensure_tables()
    case :ets.tab2list(@drafts_table) do
      [] -> load_stock_drafts()
      entries -> Enum.map(entries, fn {_k, v} -> v end)
    end
  end

  @doc """
  EPC → draft mapping ni yangilaydi.
  Har bir draft uchun items dagi serial_no (EPC) larni map qiladi.
  Format: %{normalized_epc => %{name: "SE-001", doc: full_doc}}
  """
  def put_epc_draft_mapping(mappings) when is_list(mappings) do
    ensure_tables()
    :ets.delete_all_objects(@epc_drafts_table)
    Enum.each(mappings, fn {epc, draft_info} ->
      :ets.insert(@epc_drafts_table, {epc, draft_info})
    end)
  end

  @doc """
  EPC bo'yicha lokal cache dan draft qidiradi.
  Qaytaradi: {:ok, draft_info} | :not_found
  """
  def find_draft_by_epc(epc) when is_binary(epc) do
    ensure_tables()
    case :ets.lookup(@epc_drafts_table, epc) do
      [{^epc, draft_info}] -> {:ok, draft_info}
      _ -> :not_found
    end
  end

  def delete_epc_mapping(epc) when is_binary(epc) do
    ensure_tables()
    :ets.delete(@epc_drafts_table, epc)
  end

  def search_items(query, limit \\ 50) do
    q = String.downcase(String.trim(query || ""))
    items = list_items()
    items
    |> Enum.filter(fn item ->
      if item.disabled do
        false
      else
        name = String.downcase(to_string(item.item_name || ""))
        code = String.downcase(to_string(item.name || ""))
        q == "" or String.contains?(name, q) or String.contains?(code, q)
      end
    end)
    |> Enum.take(limit)
  end

  def search_warehouses(query, limit \\ 50) do
    q = String.downcase(String.trim(query || ""))
    list_warehouses()
    |> Enum.filter(fn wh ->
      if wh.disabled or wh.is_group do
        false
      else
        name = String.downcase(to_string(wh.warehouse_name || ""))
        code = String.downcase(to_string(wh.name || ""))
        q == "" or String.contains?(name, q) or String.contains?(code, q)
      end
    end)
    |> Enum.take(limit)
  end

  def warehouses_for_item(item_code) when is_binary(item_code) do
    bins = bins_for_item(item_code)
    if bins == [] do
      :no_cache
    else
      qty_map =
        bins
        |> Enum.filter(fn bin -> (bin.actual_qty || 0) > 0 end)
        |> Enum.filter(fn bin -> is_binary(bin.warehouse) end)
        |> Enum.reduce(%{}, fn bin, acc ->
          Map.update(acc, bin.warehouse, bin.actual_qty || 0, &(&1 + (bin.actual_qty || 0)))
        end)

      if qty_map == %{}, do: :no_cache, else: {:ok, qty_map}
    end
  end

  @doc """
  Item bo'yicha omborlar kesimida actual_qty map qaytaradi (0 bo'lsa ham).

  Qaytaradi:
    {:ok, %{warehouse_name => actual_qty}}
    :no_cache (agar lokal bin cache umuman bo'sh bo'lsa)
  """
  def qty_map_for_item(item_code) when is_binary(item_code) do
    bins = bins_for_item(item_code)

    if bins == [] do
      :no_cache
    else
      qty_map =
        bins
        |> Enum.filter(fn bin -> is_binary(bin.warehouse) end)
        |> Enum.reduce(%{}, fn bin, acc ->
          Map.update(acc, bin.warehouse, bin.actual_qty || 0, &(&1 + (bin.actual_qty || 0)))
        end)

      {:ok, qty_map}
    end
  end

  @doc """
  Bitta item+warehouse uchun actual_qty.
  Qaytaradi: float/int | :unknown (agar lokal bin cache da topilmasa)
  """
  def bin_qty(item_code, warehouse)
      when is_binary(item_code) and is_binary(warehouse) do
    ensure_tables()
    key = {item_code, warehouse}

    case :ets.lookup(@bins_table, key) do
      [{^key, bin}] -> bin.actual_qty || 0
      _ -> :unknown
    end
  end

  defp bins_for_item(item_code) do
    ensure_tables()
    rows = :ets.match_object(@bins_table, {{item_code, :_}, :_})

    cond do
      rows != [] ->
        Enum.map(rows, fn {_k, v} -> v end)

      # Only load from DB when the whole table is empty. If a specific item has no bins,
      # re-loading the full table repeatedly becomes very expensive (inline queries etc).
      :ets.info(@bins_table, :size) == 0 ->
        _ = load_bins()

        case :ets.match_object(@bins_table, {{item_code, :_}, :_}) do
          [] -> []
          rows2 -> Enum.map(rows2, fn {_k, v} -> v end)
        end

      true ->
        []
    end
  end

  defp load_items do
    items = Repo.all(Item)
    put_items(items)
    items
  end

  defp load_warehouses do
    warehouses = Repo.all(Warehouse)
    put_warehouses(warehouses)
    warehouses
  end

  defp load_bins do
    bins = Repo.all(Bin)
    put_bins(bins)
    bins
  end

  defp load_stock_drafts do
    drafts = Repo.all(StockDraft)
    put_stock_drafts(drafts)
    drafts
  end

  defp create_table(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :set, :public])
      _ -> :ok
    end
  end
end
