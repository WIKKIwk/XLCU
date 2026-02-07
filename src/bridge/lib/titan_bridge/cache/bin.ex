defmodule TitanBridge.Cache.Bin do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:item_code, :warehouse, :actual_qty, :modified, :inserted_at, :updated_at]}
  @primary_key false
  schema "lce_bins" do
    field :item_code, :string, primary_key: true
    field :warehouse, :string, primary_key: true
    field :actual_qty, :float, default: 0.0
    field :modified, :string
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:item_code, :warehouse, :actual_qty, :modified])
    |> validate_required([:item_code, :warehouse])
  end
end
