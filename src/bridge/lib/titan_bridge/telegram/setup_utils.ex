defmodule TitanBridge.Telegram.SetupUtils do
  @moduledoc """
  Shared setup/validation helpers used by Telegram bots.
  """

  def valid_api_credential?(value) do
    is_binary(value) and String.length(value) == 15 and Regex.match?(~r/^[a-zA-Z0-9]+$/, value)
  end

  def normalize_erp_url(url) do
    base =
      url
      |> String.trim()
      |> ensure_scheme()
      |> String.trim_trailing("/")

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
