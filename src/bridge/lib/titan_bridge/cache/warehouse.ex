defmodule TitanBridge.Cache.Warehouse do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:name, :warehouse_name, :is_group, :disabled, :modified, :inserted_at, :updated_at]}
  @primary_key {:name, :string, []}
  schema "lce_warehouses" do
    field :warehouse_name, :string
    field :is_group, :boolean, default: false
    field :disabled, :boolean, default: false
    field :modified, :string
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :warehouse_name, :is_group, :disabled, :modified])
    |> validate_required([:name])
  end
end
