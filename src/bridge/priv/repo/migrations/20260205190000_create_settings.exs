defmodule TitanBridge.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:lce_settings, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:erp_url, :string)
      add(:erp_token, :text)
      add(:telegram_token, :text)
      add(:zebra_url, :string)
      add(:rfid_url, :string)
      add(:device_id, :string)
      add(:warehouse, :string)
      timestamps()
    end
  end
end
