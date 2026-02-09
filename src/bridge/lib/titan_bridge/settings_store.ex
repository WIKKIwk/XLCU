defmodule TitanBridge.SettingsStore do
  @moduledoc """
  CRUD wrapper for the singleton Settings record.

  - `get/0`       — load current settings (or nil)
  - `upsert/1`    — create or update settings from map
  - `masked/0`    — settings with tokens partially hidden (for API response)
  """
  alias TitanBridge.{Repo, Settings}

  @default_id 1

  def get() do
    Repo.get(Settings, @default_id)
  end

  def get_or_new() do
    get() || %Settings{id: @default_id}
  end

  def upsert(attrs) when is_map(attrs) do
    record = get_or_new()

    record
    |> Settings.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def masked() do
    case get() do
      nil -> %{}
      settings ->
        %{
          erp_url: settings.erp_url,
          erp_token: Settings.mask(settings.erp_token),
          telegram_token: Settings.mask(settings.telegram_token),
          zebra_url: settings.zebra_url,
          rfid_url: settings.rfid_url,
          rfid_telegram_token: Settings.mask(settings.rfid_telegram_token),
          device_id: settings.device_id,
          warehouse: settings.warehouse
        }
    end
  end
end
