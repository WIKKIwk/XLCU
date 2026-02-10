defmodule TitanBridge.Repo.Migrations.CreateEpcSequences do
  use Ecto.Migration

  def change do
    create table(:lce_epc_sequences, primary_key: false) do
      add(:prefix, :string, primary_key: true)
      add(:last_value, :bigint, default: 0, null: false)
      timestamps()
    end
  end
end
