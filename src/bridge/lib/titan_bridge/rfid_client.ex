defmodule TitanBridge.RfidClient do
  @moduledoc false

  alias TitanBridge.SettingsStore

  def fetch_events do
    with %{rfid_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base) do
      url = base <> "/api/events"
      case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}
        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "rfid events failed: #{status} #{body}"}
        {:error, err} -> {:error, inspect(err)}
      end
    else
      _ -> {:error, "rfid_url not configured"}
    end
  end

  def status do
    with %{rfid_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base) do
      url = base <> "/api/status"
      case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}
        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "rfid status failed: #{status} #{body}"}
        {:error, err} -> {:error, inspect(err)}
      end
    else
      _ -> {:error, "rfid_url not configured"}
    end
  end

  def last_tag_epc do
    with {:ok, %{"status" => status}} <- status(),
         %{"lastTag" => last} when is_map(last) <- status,
         epc when is_binary(epc) <- last["epcId"] do
      {:ok, epc}
    else
      _ -> {:error, "No RFID tag detected"}
    end
  end

  def write_epc(new_epc) when is_binary(new_epc) do
    with %{rfid_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base),
         {:ok, target_epc} <- last_tag_epc() do
      url = base <> "/api/write"
      payload = %{
        "epc" => target_epc,
        "mem" => 1,
        "wordPtr" => 2,
        "password" => "00000000",
        "data" => new_epc
      }
      headers = [{"content-type", "application/json"}]
      body = Jason.encode!(payload)
      case Finch.build(:post, url, headers, body) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}
        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "rfid write failed: #{status} #{body}"}
        {:error, err} -> {:error, inspect(err)}
      end
    else
      _ -> {:error, "rfid_url not configured"}
    end
  end

  defp config do
    SettingsStore.get() || %{}
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
end
