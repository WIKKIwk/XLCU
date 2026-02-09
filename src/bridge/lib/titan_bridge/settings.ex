defmodule TitanBridge.Settings do
  @moduledoc """
  Singleton settings record (id=1) — stores device configuration.

  Sensitive fields (erp_token, telegram_token) are AES-encrypted at rest.
  Configured via Telegram bot /setup flow or POST /api/config.

  Table: lce_settings
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, []}
  schema "lce_settings" do
    field :erp_url, :string
    field :erp_token, TitanBridge.Encrypted.Binary
    field :telegram_token, TitanBridge.Encrypted.Binary
    field :zebra_url, :string
    field :rfid_url, :string
    field :rfid_telegram_token, TitanBridge.Encrypted.Binary
    field :device_id, :string
    field :warehouse, :string
    timestamps()
  end

  @fields ~w(erp_url erp_token telegram_token zebra_url rfid_url rfid_telegram_token device_id warehouse)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_length(:erp_url, min: 0)
  end

  def mask(value) when is_binary(value) do
    len = String.length(value)
    if len <= 6, do: String.duplicate("*", len), else: String.slice(value, 0, 3) <> "***" <> String.slice(value, -3, 3)
  end

  def mask(_), do: nil
end
