defmodule TitanBridge.ErpClient do
  @moduledoc """
  ERPNext HTTP API client — reads/writes data from the ERP ledger.

  Uses Finch HTTP pool. All calls require erp_url + erp_token in Settings.

  Read operations (used by ErpSyncWorker):
    - list_items_modified/1       — fetch items changed since timestamp
    - list_warehouses_modified/1  — fetch warehouses
    - list_bins_modified/1        — fetch bin/stock levels
    - list_stock_drafts/0         — fetch pending Stock Entry drafts

  Write operations (used by Telegram bot):
    - create_draft/1              — create Stock Entry (Material Issue) draft
    - epc_exists?/1               — check if EPC tag exists in ERP

  Auth: Frappe token-based (api_key:api_secret in Authorization header).
  """

  alias TitanBridge.SettingsStore

  def list_items_modified(since \\ nil) do
    filters =
      build_modified_filters("Item", since) ++
        [["Item", "is_stock_item", "=", 1]]

    list_resource("Item", ["name", "item_name", "stock_uom", "disabled", "modified"], filters)
  end

  def list_warehouses_modified(since \\ nil) do
    list_resource("Warehouse", ["name", "warehouse_name", "is_group", "disabled", "modified"],
      build_modified_filters("Warehouse", since)
    )
  end

  def list_bins_modified(since \\ nil) do
    list_resource("Bin", ["item_code", "warehouse", "actual_qty", "modified"],
      build_modified_filters("Bin", since)
    )
  end

  def list_stock_drafts_modified(since \\ nil) do
    filters =
      build_modified_filters("Stock Entry", since) ++
        [["Stock Entry", "docstatus", "=", 0]]

    list_resource("Stock Entry", ["name", "docstatus", "purpose", "posting_date", "posting_time", "from_warehouse", "to_warehouse", "modified"], filters)
  end

  def list_products(warehouse \\ nil) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base),
         {:ok, items} <- fetch_items(base, token),
         {:ok, filtered} <- filter_by_warehouse(base, token, items, warehouse) do
      {:ok, filtered}
    else
      false -> {:error, "ERP config missing"}
      {:error, _} = err -> err
    end
  end

  def list_warehouses do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      fields = Jason.encode!(["name", "warehouse_name", "is_group", "disabled"])
      filters = Jason.encode!([
        ["Warehouse", "is_group", "=", 0],
        ["Warehouse", "disabled", "=", 0]
      ])
      url = base <> "/api/resource/Warehouse?fields=" <> URI.encode(fields)
        <> "&filters=" <> URI.encode(filters)
        <> "&limit_page_length=200"

      case http_get(url, token) do
        {:ok, %{"data" => data}} -> {:ok, data}
        {:ok, _} -> {:error, "Invalid ERP response"}
        {:error, _} = err -> err
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  def list_warehouses_for_product(item_code) when is_binary(item_code) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base),
         {:ok, bins} <- fetch_bins_for_item(base, token, item_code) do
      names =
        bins
        |> Enum.map(& &1["warehouse"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()

      if names == [] do
        {:ok, []}
      else
        fetch_warehouses_by_names(base, token, names)
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  def list_warehouses_for_product(_), do: {:ok, []}

  def create_log(attrs) do
    post_doc("Telegram Log", attrs)
  end

  def create_draft(attrs) do
    stock_entry = %{
      "doctype" => "Stock Entry",
      "stock_entry_type" => "Material Receipt",
      "to_warehouse" => attrs["warehouse"],
      "items" => [
        %{
          "item_code" => attrs["product_id"],
          "qty" => attrs["weight_kg"],
          "t_warehouse" => attrs["warehouse"]
        }
      ]
    }
    post_doc("Stock Entry", stock_entry)
  end

  def upsert_device(attrs) do
    upsert_by_field("Telegram Device", "device_id", attrs["device_id"], attrs)
  end

  def upsert_session(attrs) do
    upsert_by_field("Telegram Session", "chat_id", attrs["chat_id"], attrs)
  end

  def ping do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url = base <> "/api/method/frappe.ping"
      http_get(url, token)
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  def get_doc(doctype, name) when is_binary(doctype) and is_binary(name) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url = base <> "/api/resource/" <> URI.encode(doctype) <> "/" <> URI.encode(name)
      case http_get(url, token) do
        {:ok, %{"data" => data}} -> {:ok, data}
        {:ok, _} -> {:error, "Invalid ERP response"}
        {:error, _} = err -> err
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  def epc_exists?(epc) when is_binary(epc) do
    filters = Jason.encode!([["LCE Draft", "epc_code", "=", epc]])
    fields = Jason.encode!(["name"])

    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url = base <> "/api/resource/LCE%20Draft?fields=" <> URI.encode(fields)
        <> "&filters=" <> URI.encode(filters)
        <> "&limit_page_length=1"

      case http_get(url, token) do
        {:ok, %{"data" => [row | _]}} -> {:ok, row["name"]}
        {:ok, _} -> :not_found
        {:error, _} = err -> err
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  def get_config do
    SettingsStore.get()
    |> case do
      nil -> %{}
      settings ->
        %{
          erp_url: settings.erp_url,
          erp_token: settings.erp_token,
          warehouse: settings.warehouse,
          device_id: settings.device_id
        }
    end
  end

  defp valid?(base, token) when is_binary(base) and is_binary(token) do
    String.trim(base) != "" and String.trim(token) != ""
  end

  defp valid?(_, _), do: false

  defp fetch_items(base, token) do
    filters = Jason.encode!([["Item", "is_stock_item", "=", 1]])
    fields = Jason.encode!(["name", "item_name", "stock_uom"])
    url = base <> "/api/resource/Item?fields=" <> URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=200"

    case http_get(url, token) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp filter_by_warehouse(_base, _token, items, nil), do: {:ok, items}
  defp filter_by_warehouse(base, token, items, warehouse) when is_binary(warehouse) do
    warehouse = String.trim(warehouse)
    if warehouse == "" do
      {:ok, items}
    else
      bins = fetch_bins(base, token, warehouse)
      case bins do
        {:ok, item_codes} ->
          filtered = Enum.filter(items, fn item -> item["name"] in item_codes end)
          {:ok, filtered}
        {:error, _} -> {:ok, items}
      end
    end
  end

  defp fetch_bins(base, token, warehouse) do
    filters = Jason.encode!([
      ["Bin", "warehouse", "=", warehouse],
      ["Bin", "actual_qty", ">", 0]
    ])
    fields = Jason.encode!(["item_code"])
    url = base <> "/api/resource/Bin?fields=" <> URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

    case http_get(url, token) do
      {:ok, %{"data" => data}} ->
        codes = data |> Enum.map(& &1["item_code"]) |> Enum.uniq()
        {:ok, codes}
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp fetch_bins_for_item(base, token, item_code) do
    filters = Jason.encode!([
      ["Bin", "item_code", "=", item_code],
      ["Bin", "actual_qty", ">", 0]
    ])
    fields = Jason.encode!(["warehouse"])
    url = base <> "/api/resource/Bin?fields=" <> URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

    case http_get(url, token) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp fetch_warehouses_by_names(base, token, names) when is_list(names) do
    fields = Jason.encode!(["name", "warehouse_name"])
    filters = Jason.encode!([["Warehouse", "name", "in", names]])
    url = base <> "/api/resource/Warehouse?fields=" <> URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

    case http_get(url, token) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp post_doc(doctype, attrs) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url = base <> "/api/resource/" <> URI.encode(doctype)
      payload = Map.put(attrs, "doctype", doctype)
      http_post(url, token, payload)
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp upsert_by_field(doctype, field, value, attrs) when is_binary(value) and value != "" do
    case find_doc_name(doctype, field, value) do
      {:ok, name} -> put_doc(doctype, name, attrs)
      :not_found -> post_doc(doctype, attrs)
      {:error, _} = err -> err
    end
  end

  defp upsert_by_field(_, _, _, _), do: {:error, "Invalid upsert key"}

  defp find_doc_name(doctype, field, value) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      filters = Jason.encode!([[doctype, field, "=", value]])
      fields = Jason.encode!(["name"])
      url = base <> "/api/resource/" <> URI.encode(doctype)
        <> "?fields=" <> URI.encode(fields)
        <> "&filters=" <> URI.encode(filters)
        <> "&limit_page_length=1"

      case http_get(url, token) do
        {:ok, %{"data" => [row | _]}} -> {:ok, row["name"]}
        {:ok, _} -> :not_found
        {:error, _} = err -> err
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp put_doc(doctype, name, attrs) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url = base <> "/api/resource/" <> URI.encode(doctype) <> "/" <> URI.encode(name)
      payload = Map.delete(attrs, "doctype")
      http_put(url, token, payload)
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp http_get(url, token) do
    headers = auth_headers(token)
    case Finch.build(:get, url, headers) |> Finch.request(TitanBridgeFinch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP GET failed: #{status} #{body}"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp http_post(url, token, payload) do
    headers = auth_headers(token) ++ [{"content-type", "application/json"}]
    body = Jason.encode!(payload)
    case Finch.build(:post, url, headers, body) |> Finch.request(TitanBridgeFinch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP POST failed: #{status} #{body}"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp http_put(url, token, payload) do
    headers = auth_headers(token) ++ [{"content-type", "application/json"}]
    body = Jason.encode!(payload)
    case Finch.build(:put, url, headers, body) |> Finch.request(TitanBridgeFinch) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP PUT failed: #{status} #{body}"}
      {:error, err} -> {:error, inspect(err)}
    end
  end

  defp auth_headers(token) do
    t = String.trim(token || "")
    if t == "" do
      []
    else
      header = if String.starts_with?(t, "token "), do: t, else: "token " <> t
      [{"authorization", header}]
    end
  end

  defp normalize_base(base) when is_binary(base) do
    base = String.trim_trailing(String.trim(base), "/")
    base = ensure_scheme(base)
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

  defp list_resource(doctype, fields, filters) when is_list(fields) and is_list(filters) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      fetch_all(base, token, doctype, fields, filters, 0, [])
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp fetch_all(base, token, doctype, fields, filters, start, acc) do
    limit = 200
    fields_json = Jason.encode!(fields)
    filters_json = Jason.encode!(filters)
    url = base <> "/api/resource/" <> URI.encode(doctype)
      <> "?fields=" <> URI.encode(fields_json)
      <> "&filters=" <> URI.encode(filters_json)
      <> "&limit_page_length=" <> Integer.to_string(limit)
      <> "&limit_start=" <> Integer.to_string(start)

    case http_get(url, token) do
      {:ok, %{"data" => data}} when is_list(data) ->
        new_acc = acc ++ data
        if length(data) == limit do
          fetch_all(base, token, doctype, fields, filters, start + limit, new_acc)
        else
          {:ok, new_acc}
        end
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp build_modified_filters(doctype, nil), do: [[doctype, "modified", ">", "1970-01-01 00:00:00"]]
  defp build_modified_filters(doctype, since) when is_binary(since) do
    [[doctype, "modified", ">=", since]]
  end
end
