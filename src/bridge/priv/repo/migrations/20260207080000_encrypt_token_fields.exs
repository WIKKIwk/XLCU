defmodule TitanBridge.Repo.Migrations.EncryptTokenFields do
  use Ecto.Migration

  def up do
    # Clear existing plaintext tokens before changing column type.
    # Users will re-enter tokens via Telegram bot — they'll be encrypted.
    execute "UPDATE lce_settings SET erp_token = NULL, telegram_token = NULL"
    execute "ALTER TABLE lce_settings ALTER COLUMN erp_token TYPE bytea USING NULL"
    execute "ALTER TABLE lce_settings ALTER COLUMN telegram_token TYPE bytea USING NULL"
  end

  def down do
    execute "ALTER TABLE lce_settings ALTER COLUMN erp_token TYPE text USING NULL"
    execute "ALTER TABLE lce_settings ALTER COLUMN telegram_token TYPE text USING NULL"
  end
end
