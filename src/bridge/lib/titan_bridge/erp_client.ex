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

  @doc """
  Telegram/UI uchun ERP xatolarini qisqa va tushunarli ko'rinishga keltiradi.

  Masalan:
    - "ERP POST failed: 403 {...}" → "HTTP 403 (POST): Not permitted"
    - network xatolari            → "request_error: ..."
  """
  def human_error(reason) do
    text =
      cond do
        is_binary(reason) -> reason
        true -> inspect(reason)
      end

    case parse_http_failed(text) do
      {:ok, method, status, body} ->
        detail = extract_frappe_error(body) || short_body(body)
        "HTTP #{status} (#{method}): #{detail}"

      :error ->
        case String.trim(text) do
          "" -> "unknown error"
          other -> String.slice(other, 0, 240)
        end
    end
  end

  defp parse_http_failed(text) when is_binary(text) do
    # "ERP POST failed: 403 {json...}"
    case Regex.run(~r/^ERP\s+(GET|POST|PUT)\s+failed:\s+(\d+)\s+(.*)$/s, text) do
      [_, method, status_str, body] ->
        status =
          case Integer.parse(status_str) do
            {n, _} -> n
            _ -> 0
          end

        {:ok, method, status, body}

      _ ->
        :error
    end
  end

  defp extract_frappe_error(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body) do
      server_msg =
        case decoded["_server_messages"] do
          msgs when is_binary(msgs) ->
            case Jason.decode(msgs) do
              {:ok, [first | _]} ->
                extract_server_message(first) || extract_server_message_text(first)

              _ ->
                nil
            end

          _ ->
            nil
        end

      msg =
        cond do
          is_binary(server_msg) and String.trim(server_msg) != "" ->
            server_msg

          is_binary(decoded["message"]) and String.trim(decoded["message"]) != "" ->
            decoded["message"]

          true ->
            nil
        end

      exc = decoded["exc_type"] || decoded["exception"]
      exc_type = decoded["exc_type"]
      exception = decoded["exception"]

      cond do
        is_binary(exc) and is_binary(msg) ->
          "#{exc}: #{msg}" |> String.replace(~r/\s+/, " ") |> String.slice(0, 220)

        is_binary(msg) ->
          msg |> String.replace(~r/\s+/, " ") |> String.slice(0, 220)

        # Some ERPNext errors (e.g. auth) only return `exc_type` + traceback without `message`.
        is_binary(exc_type) and String.trim(exc_type) != "" ->
          exc_type |> String.replace(~r/\s+/, " ") |> String.slice(0, 220)

        is_binary(exception) and String.trim(exception) != "" ->
          exception
          |> String.split(".")
          |> List.last()
          |> to_string()
          |> String.replace(~r/\s+/, " ")
          |> String.slice(0, 220)

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp extract_frappe_error(_), do: nil

  defp extract_server_message(msg_json) when is_binary(msg_json) do
    case Jason.decode(msg_json) do
      {:ok, %{"message" => msg}} when is_binary(msg) -> msg
      _ -> nil
    end
  end

  defp extract_server_message(_), do: nil

  defp extract_server_message_text(msg) when is_binary(msg) do
    # If it's not JSON, return as-is (trimmed).
    m = String.trim(msg)
    if m == "", do: nil, else: m
  end

  defp extract_server_message_text(_), do: nil

  defp short_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 220)
  end

  def list_items_modified(since \\ nil) do
    filters =
      build_modified_filters("Item", since) ++
        [["Item", "is_stock_item", "=", 1]]

    list_resource("Item", ["name", "item_name", "stock_uom", "disabled", "modified"], filters)
  end

  def list_warehouses_modified(since \\ nil) do
    list_resource(
      "Warehouse",
      ["name", "warehouse_name", "is_group", "disabled", "modified"],
      build_modified_filters("Warehouse", since)
    )
  end

  def list_bins_modified(since \\ nil) do
    list_resource(
      "Bin",
      ["item_code", "warehouse", "actual_qty", "modified"],
      build_modified_filters("Bin", since)
    )
  end

  def list_stock_drafts_modified(since \\ nil) do
    filters =
      build_modified_filters("Stock Entry", since) ++
        [["Stock Entry", "docstatus", "=", 0]]

    list_resource(
      "Stock Entry",
      [
        "name",
        "docstatus",
        "purpose",
        "posting_date",
        "posting_time",
        "from_warehouse",
        "to_warehouse",
        "modified"
      ],
      filters
    )
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

      filters =
        Jason.encode!([
          ["Warehouse", "is_group", "=", 0],
          ["Warehouse", "disabled", "=", 0]
        ])

      url =
        base <>
          "/api/resource/Warehouse?fields=" <>
          URI.encode(fields) <>
          "&filters=" <>
          URI.encode(filters) <>
          "&limit_page_length=200"

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
    epc = String.trim(attrs["epc_code"] || "")

    item =
      %{
        "item_code" => attrs["product_id"],
        "qty" => attrs["weight_kg"],
        "s_warehouse" => attrs["warehouse"]
      }
      |> then(fn m ->
        if epc == "" do
          m
        else
          # EPC should live in the Stock Entry item row for easy scanning in ERPNext UI.
          # Using `barcode` avoids Serial/Batch validation.
          Map.put(m, "barcode", epc)
        end
      end)

    stock_entry = %{
      "doctype" => "Stock Entry",
      # Our flow removes stock from the selected warehouse (draft = docstatus 0).
      "stock_entry_type" => "Material Issue",
      "from_warehouse" => attrs["warehouse"],
      "items" => [item]
    }

    case post_doc("Stock Entry", stock_entry) do
      {:ok, %{"data" => %{"name" => name}} = resp} when is_binary(name) and name != "" ->
        # Best-effort: keep ERP-side EPC registry for uniqueness / audits.
        _ =
          if epc != "" do
            device_id = attrs["device_id"] || get_config()[:device_id] || "LCE"

            post_doc("LCE Draft", %{
              "device_id" => device_id,
              "product_id" => attrs["product_id"],
              "warehouse" => attrs["warehouse"],
              "weight_kg" => attrs["weight_kg"],
              "epc_code" => epc,
              "status" => "Draft",
              "message" => "Stock Entry: #{name}"
            })
          else
            :ok
          end

        {:ok, resp}

      other ->
        other
    end
  end

  def submit_stock_entry(name) when is_binary(name) do
    put_doc("Stock Entry", name, %{"docstatus" => 1})
  end

  def list_drafts_with_epc do
    case list_stock_drafts_modified(nil) do
      {:ok, drafts} ->
        results =
          drafts
          |> Enum.map(fn draft ->
            case get_doc("Stock Entry", draft["name"]) do
              {:ok, doc} ->
                items = doc["items"] || []

                epcs =
                  Enum.flat_map(items, fn item ->
                    barcode = String.trim(item["barcode"] || "")
                    batch = String.trim(item["batch_no"] || "")
                    serial = String.trim(item["serial_no"] || "")

                    serials =
                      if serial != "" do
                        # serial_no can contain multiple values separated by whitespace/newlines
                        serial
                        |> String.split(~r/[\s,]+/, trim: true)
                        |> Enum.map(&String.trim/1)
                        |> Enum.filter(&(&1 != ""))
                      else
                        []
                      end

                    cond do
                      barcode != "" or batch != "" or serials != [] ->
                        Enum.filter([barcode, batch], &(&1 != "")) ++ serials

                      true ->
                        []
                    end
                  end)

                epcs =
                  case extract_epc_from_remarks(doc["remarks"]) do
                    nil -> epcs
                    remark_epc -> [remark_epc | epcs]
                  end

                %{
                  name: doc["name"],
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

              {:error, _} ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn d -> d.epcs != [] end)

        {:ok, results}

      {:error, _} = err ->
        err
    end
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

  @doc """
  EPC bo'yicha draft Stock Entry ni qidiradi.

  Primary key: `batch_no` (recommended).
  Fallback: `serial_no` (legacy / older drafts).

  Qaytaradi:
    {:ok, doc}     — topildi (to'liq Stock Entry doc)
    :not_found     — mos draft yo'q
    {:error, ...}  — xato
  """
  def find_draft_by_serial_no(epc) when is_binary(epc) do
    case find_open_draft_name_by_epc(epc) do
      {:ok, name} -> get_doc("Stock Entry", name)
      other -> other
    end
  end

  @doc """
  EPC bo'yicha faqat OCHIQ (docstatus=0) Stock Entry nomini topadi.

  Qaytaradi:
    {:ok, name}   — topildi
    :not_found    — mos draft yo'q
    {:error, ...} — xato
  """
  def find_open_draft_name_by_epc(epc) when is_binary(epc) do
    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      fields = Jason.encode!(["parent"])
      parent = URI.encode("Stock Entry")

      # 0) Barcode bo'yicha qidirish (asosiy)
      barcode_filters =
        Jason.encode!([
          ["Stock Entry Detail", "barcode", "=", epc],
          ["Stock Entry Detail", "docstatus", "=", 0]
        ])

      case find_draft_name_via_details(base, token, fields, parent, epc, barcode_filters) do
        {:ok, _} = ok ->
          ok

        {:error, _} = err ->
          err

        :not_found ->
          case find_draft_name_by_remarks(base, token, epc) do
            {:ok, _} = ok ->
              ok

            :not_found ->
              # Final fallback: some ERP roles cannot query Stock Entry Detail,
              # so scan open Stock Entry docs directly and match EPC in items/remarks.
              find_draft_name_by_items_scan(base, token, epc)

            {:error, _} = err ->
              err
          end
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp find_draft_name_via_details(base, token, fields, parent, epc, barcode_filters) do
    case stock_entry_detail_parent(base, token, fields, barcode_filters, parent) do
      {:ok, draft_name} ->
        {:ok, draft_name}

      {:error, reason} ->
        if detail_lookup_fallback?(reason),
          do: find_draft_name_via_batch_or_serial(base, token, fields, parent, epc),
          else: {:error, reason}

      :not_found ->
        find_draft_name_via_batch_or_serial(base, token, fields, parent, epc)
    end
  end

  defp find_draft_name_via_batch_or_serial(base, token, fields, parent, epc) do
    batch_filters =
      Jason.encode!([
        ["Stock Entry Detail", "batch_no", "=", epc],
        ["Stock Entry Detail", "docstatus", "=", 0]
      ])

    case stock_entry_detail_parent(base, token, fields, batch_filters, parent) do
      {:ok, draft_name} ->
        {:ok, draft_name}

      {:error, reason} ->
        if detail_lookup_fallback?(reason),
          do: find_draft_name_via_serial(base, token, fields, parent, epc),
          else: {:error, reason}

      :not_found ->
        find_draft_name_via_serial(base, token, fields, parent, epc)
    end
  end

  defp find_draft_name_via_serial(base, token, fields, parent, epc) do
    filters =
      Jason.encode!([
        ["Stock Entry Detail", "serial_no", "like", "%#{epc}%"],
        ["Stock Entry Detail", "docstatus", "=", 0]
      ])

    case stock_entry_detail_parent(base, token, fields, filters, parent) do
      {:ok, draft_name} ->
        {:ok, draft_name}

      {:error, reason} ->
        if detail_lookup_fallback?(reason), do: :not_found, else: {:error, reason}

      :not_found ->
        :not_found
    end
  end

  defp stock_entry_detail_parent(base, token, fields, filters, parent) do
    with_parent =
      base <>
        "/api/resource/Stock%20Entry%20Detail?fields=" <>
        URI.encode(fields) <>
        "&filters=" <>
        URI.encode(filters) <>
        "&parent=" <>
        parent <>
        "&limit_page_length=1"

    without_parent =
      base <>
        "/api/resource/Stock%20Entry%20Detail?fields=" <>
        URI.encode(fields) <>
        "&filters=" <>
        URI.encode(filters) <>
        "&limit_page_length=1"

    case http_get(with_parent, token) do
      {:error, reason} when is_binary(reason) ->
        if parent_join_bug?(reason) do
          parse_stock_entry_detail_parent(http_get(without_parent, token))
        else
          {:error, reason}
        end

      other ->
        parse_stock_entry_detail_parent(other)
    end
  end

  defp parse_stock_entry_detail_parent({:ok, %{"data" => [%{"parent" => draft_name} | _]}})
       when is_binary(draft_name) do
    {:ok, draft_name}
  end

  defp parse_stock_entry_detail_parent({:ok, %{"data" => []}}), do: :not_found
  defp parse_stock_entry_detail_parent({:ok, _}), do: :not_found
  defp parse_stock_entry_detail_parent({:error, _} = err), do: err

  defp parent_join_bug?(reason) when is_binary(reason) do
    String.contains?(reason, "Unknown column 'tabStock Entry.parenttype'") or
      String.contains?(reason, "Unknown column \\\"tabStock Entry.parenttype\\\"")
  end

  defp detail_lookup_fallback?(reason) when is_binary(reason) do
    String.starts_with?(reason, "ERP GET failed:")
  end

  defp detail_lookup_fallback?(_), do: false

  def epc_exists?(epc) when is_binary(epc) do
    filters = Jason.encode!([["LCE Draft", "epc_code", "=", epc]])
    fields = Jason.encode!(["name"])

    with %{erp_url: base, erp_token: token} <- get_config(),
         true <- valid?(base, token),
         base <- normalize_base(base) do
      url =
        base <>
          "/api/resource/LCE%20Draft?fields=" <>
          URI.encode(fields) <>
          "&filters=" <>
          URI.encode(filters) <>
          "&limit_page_length=1"

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
      nil ->
        %{}

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
    # list_products/1 is a user-facing flow; don't silently cap at 200 rows.
    fetch_all(
      base,
      token,
      "Item",
      ["name", "item_name", "stock_uom"],
      [["Item", "is_stock_item", "=", 1]],
      0,
      []
    )
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

        {:error, _} ->
          {:ok, items}
      end
    end
  end

  defp fetch_bins(base, token, warehouse) do
    filters =
      Jason.encode!([
        ["Bin", "warehouse", "=", warehouse],
        ["Bin", "actual_qty", ">", 0]
      ])

    fields = Jason.encode!(["item_code"])

    url =
      base <>
        "/api/resource/Bin?fields=" <>
        URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

    case http_get(url, token) do
      {:ok, %{"data" => data}} ->
        codes = data |> Enum.map(& &1["item_code"]) |> Enum.uniq()
        {:ok, codes}

      {:ok, _} ->
        {:error, "Invalid ERP response"}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_bins_for_item(base, token, item_code) do
    filters =
      Jason.encode!([
        ["Bin", "item_code", "=", item_code],
        ["Bin", "actual_qty", ">", 0]
      ])

    fields = Jason.encode!(["warehouse"])

    url =
      base <>
        "/api/resource/Bin?fields=" <>
        URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

    case http_get(url, token) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, _} -> {:error, "Invalid ERP response"}
      {:error, _} = err -> err
    end
  end

  defp fetch_warehouses_by_names(base, token, names) when is_list(names) do
    fields = Jason.encode!(["name", "warehouse_name"])
    filters = Jason.encode!([["Warehouse", "name", "in", names]])

    url =
      base <>
        "/api/resource/Warehouse?fields=" <>
        URI.encode(fields) <> "&filters=" <> URI.encode(filters) <> "&limit_page_length=500"

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

      url =
        base <>
          "/api/resource/" <>
          URI.encode(doctype) <>
          "?fields=" <>
          URI.encode(fields) <>
          "&filters=" <>
          URI.encode(filters) <>
          "&limit_page_length=1"

      case http_get(url, token) do
        {:ok, %{"data" => [row | _]}} -> {:ok, row["name"]}
        {:ok, _} -> :not_found
        {:error, _} = err -> err
      end
    else
      _ -> {:error, "ERP config missing"}
    end
  end

  defp find_draft_name_by_remarks(base, token, epc) when is_binary(epc) do
    epc = String.trim(epc)

    if epc == "" do
      :not_found
    else
      filters =
        Jason.encode!([
          ["Stock Entry", "remarks", "like", "%#{epc}%"],
          ["Stock Entry", "docstatus", "=", 0]
        ])

      fields = Jason.encode!(["name"])

      url =
        base <>
          "/api/resource/Stock%20Entry?fields=" <>
          URI.encode(fields) <>
          "&filters=" <>
          URI.encode(filters) <>
          "&limit_page_length=1"

      case http_get(url, token) do
        {:ok, %{"data" => [%{"name" => name} | _]}} when is_binary(name) ->
          {:ok, name}

        _ ->
          :not_found
      end
    end
  end

  defp find_draft_name_by_items_scan(base, token, epc) when is_binary(epc) do
    normalized_epc = normalize_epc(epc)

    if normalized_epc == "" do
      :not_found
    else
      filters = [["Stock Entry", "docstatus", "=", 0]]
      fields = ["name", "modified"]

      case fetch_all(base, token, "Stock Entry", fields, filters, 0, []) do
        {:ok, rows} ->
          rows
          |> Enum.filter(&is_binary(&1["name"]))
          |> Enum.sort_by(&to_string(&1["modified"] || ""), :desc)
          |> Enum.map(& &1["name"])
          |> Enum.take(300)
          |> Task.async_stream(
            fn name -> stock_entry_matches_epc?(base, token, name, normalized_epc) end,
            ordered: false,
            max_concurrency: 8,
            timeout: min(max(erp_timeout_ms(), 5_000), 20_000)
          )
          |> Enum.find_value(:not_found, fn
            {:ok, {:ok, name}} -> {:ok, name}
            _ -> nil
          end)

        _ ->
          :not_found
      end
    end
  end

  defp stock_entry_matches_epc?(base, token, name, normalized_epc)
       when is_binary(name) and is_binary(normalized_epc) do
    url = base <> "/api/resource/Stock%20Entry/" <> URI.encode(name)

    case http_get(url, token) do
      {:ok, %{"data" => doc}} when is_map(doc) ->
        if stock_entry_doc_has_epc?(doc, normalized_epc) do
          {:ok, name}
        else
          :not_found
        end

      _ ->
        :not_found
    end
  end

  defp stock_entry_doc_has_epc?(doc, normalized_epc)
       when is_map(doc) and is_binary(normalized_epc) do
    items = doc["items"] || []

    item_epcs =
      items
      |> Enum.flat_map(fn item ->
        barcode = normalize_epc(item["barcode"] || "")
        batch = normalize_epc(item["batch_no"] || "")
        serial = to_string(item["serial_no"] || "")

        serials =
          if String.trim(serial) == "" do
            []
          else
            serial
            |> String.split(~r/[\s,]+/, trim: true)
            |> Enum.map(&normalize_epc/1)
          end

        [barcode, batch | serials]
      end)

    remark_epcs =
      case extract_epc_from_remarks(doc["remarks"]) do
        epc when is_binary(epc) -> [normalize_epc(epc)]
        _ -> []
      end

    item_epcs
    |> Kernel.++(remark_epcs)
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
    |> Enum.member?(normalized_epc)
  end

  defp stock_entry_doc_has_epc?(_, _), do: false

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

  defp normalize_epc(raw) do
    raw
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^0-9A-F]/, "")
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

    case Finch.build(:get, url, headers) |> Finch.request(TitanBridgeFinch, finch_opts()) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP GET failed: #{status} #{body}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp http_post(url, token, payload) do
    headers = auth_headers(token) ++ [{"content-type", "application/json"}]
    body = Jason.encode!(payload)

    case Finch.build(:post, url, headers, body)
         |> Finch.request(TitanBridgeFinch, finch_opts()) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP POST failed: #{status} #{body}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp http_put(url, token, payload) do
    headers = auth_headers(token) ++ [{"content-type", "application/json"}]
    body = Jason.encode!(payload)

    case Finch.build(:put, url, headers, body) |> Finch.request(TitanBridgeFinch, finch_opts()) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "ERP PUT failed: #{status} #{body}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp finch_opts do
    # Hard timeouts: prevent Telegram bot flow from "freezing" if ERP becomes slow/unreachable.
    [receive_timeout: erp_timeout_ms(), pool_timeout: 5_000]
  end

  defp erp_timeout_ms do
    case Integer.parse(to_string(System.get_env("LCE_ERP_TIMEOUT_MS") || "")) do
      {n, _} when n >= 1_000 and n <= 120_000 -> n
      _ -> 15_000
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
      nil ->
        base

      "" ->
        base

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

    url =
      base <>
        "/api/resource/" <>
        URI.encode(doctype) <>
        "?fields=" <>
        URI.encode(fields_json) <>
        "&filters=" <>
        URI.encode(filters_json) <>
        "&limit_page_length=" <>
        Integer.to_string(limit) <>
        "&limit_start=" <> Integer.to_string(start)

    case http_get(url, token) do
      {:ok, %{"data" => data}} when is_list(data) ->
        new_acc = acc ++ data

        if length(data) == limit do
          fetch_all(base, token, doctype, fields, filters, start + limit, new_acc)
        else
          {:ok, new_acc}
        end

      {:ok, _} ->
        {:error, "Invalid ERP response"}

      {:error, _} = err ->
        err
    end
  end

  defp build_modified_filters(doctype, nil),
    do: [[doctype, "modified", ">", "1970-01-01 00:00:00"]]

  defp build_modified_filters(doctype, since) when is_binary(since) do
    [[doctype, "modified", ">=", since]]
  end
end
