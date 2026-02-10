defmodule TitanBridge.ZebraClient do
  @moduledoc false

  alias TitanBridge.SettingsStore

  def scale_reading do
    with %{zebra_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base) do
      url = base <> "/api/v1/scale"

      case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "zebra scale failed: #{status} #{body}"}

        {:error, err} ->
          {:error, inspect(err)}
      end
    else
      _ -> {:error, "zebra_url not configured"}
    end
  end

  def encode(epc, opts \\ %{}) do
    with %{zebra_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base) do
      url = base <> "/api/v1/encode"
      payload = Map.merge(%{"epc" => epc, "copies" => 1, "printHumanReadable" => false}, opts)
      body = Jason.encode!(payload)
      headers = [{"content-type", "application/json"}]

      case Finch.build(:post, url, headers, body) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "zebra encode failed: #{status} #{body}"}

        {:error, err} ->
          {:error, inspect(err)}
      end
    else
      _ -> {:error, "zebra_url not configured"}
    end
  end

  def health do
    with %{zebra_url: base} <- config(),
         true <- is_binary(base) and String.trim(base) != "",
         base <- normalize_base(base) do
      url = base <> "/api/v1/health"

      case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch) do
        {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, Jason.decode!(body)}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, "zebra health failed: #{status} #{body}"}

        {:error, err} ->
          {:error, inspect(err)}
      end
    else
      _ -> {:error, "zebra_url not configured"}
    end
  end

  defp config do
    SettingsStore.get() || %{}
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
end
