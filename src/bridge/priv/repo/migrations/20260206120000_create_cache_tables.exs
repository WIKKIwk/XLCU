defmodule TitanBridge.Repo.Migrations.CreateCacheTables do
  use Ecto.Migration

  def change do
    create table(:lce_items, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:item_name, :string)
      add(:stock_uom, :string)
      add(:disabled, :boolean, default: false, null: false)
      add(:modified, :string)
      timestamps()
    end

    create table(:lce_warehouses, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:warehouse_name, :string)
      add(:is_group, :boolean, default: false, null: false)
      add(:disabled, :boolean, default: false, null: false)
      add(:modified, :string)
      timestamps()
    end

    create table(:lce_bins, primary_key: false) do
      add(:item_code, :string, primary_key: true)
      add(:warehouse, :string, primary_key: true)
      add(:actual_qty, :float, default: 0, null: false)
      add(:modified, :string)
      timestamps()
    end

    create table(:lce_stock_drafts, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:docstatus, :integer)
      add(:purpose, :string)
      add(:posting_date, :string)
      add(:posting_time, :string)
      add(:from_warehouse, :string)
      add(:to_warehouse, :string)
      add(:modified, :string)
      add(:data, :map)
      timestamps()
    end

    create table(:lce_sync_state, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :string)
      timestamps()
    end

    create table(:lce_epc_registry, primary_key: false) do
      add(:epc, :string, primary_key: true)
      add(:source, :string)
      add(:status, :string)
      timestamps()
    end
  end
end
