defmodule TitanBridge.Status do
  @moduledoc """
  System snapshot builder for GET /api/status endpoint.

  Aggregates: settings, cache versions, Telegram state,
  connected Core devices, and service health (ERP, Zebra, RFID).
  """

  alias TitanBridge.{CoreHub, SettingsStore, ErpClient, ZebraClient, RfidClient, Children}

  def snapshot do
    settings = SettingsStore.get()
    masked = SettingsStore.masked()

    %{
      ok: true,
      server_time: DateTime.utc_now(),
      config: masked,
      cache_versions: %{
        items: TitanBridge.Cache.version(:items),
        warehouses: TitanBridge.Cache.version(:warehouses),
        bins: TitanBridge.Cache.version(:bins),
        stock_drafts: TitanBridge.Cache.version(:stock_drafts)
      },
      telegram: %{token_set: token_set?(settings)},
      core: %{devices: core_devices()},
      services: %{
        erp: result(ErpClient.ping()),
        zebra: result(ZebraClient.health()),
        rfid: result(RfidClient.status())
      },
      children: children_status()
    }
  end

  defp token_set?(%{telegram_token: token}) when is_binary(token) do
    String.trim(token) != ""
  end

  defp token_set?(_), do: false

  defp result({:ok, data}), do: %{ok: true, data: data}
  defp result({:error, reason}), do: %{ok: false, error: reason}
  defp result(other), do: %{ok: false, error: inspect(other)}

  defp children_status do
    try do
      Children.status()
    catch
      _, _ -> []
    end
  end

  defp core_devices do
    try do
      CoreHub.list_devices()
    catch
      _, _ -> []
    end
  end
end
