defmodule TitanBridge.Cache.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [:name, :item_name, :stock_uom, :disabled, :modified, :inserted_at, :updated_at]}
  @primary_key {:name, :string, []}
  schema "lce_items" do
    field(:item_name, :string)
    field(:stock_uom, :string)
    field(:disabled, :boolean, default: false)
    field(:modified, :string)
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :item_name, :stock_uom, :disabled, :modified])
    |> validate_required([:name])
  end
end
