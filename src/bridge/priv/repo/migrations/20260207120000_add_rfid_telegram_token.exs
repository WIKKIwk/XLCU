defmodule TitanBridge.Repo.Migrations.AddRfidTelegramToken do
  use Ecto.Migration

  def change do
    alter table(:lce_settings) do
      add :rfid_telegram_token, :binary
    end
  end
end
