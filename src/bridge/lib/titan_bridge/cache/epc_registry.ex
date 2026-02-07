defmodule TitanBridge.Cache.EpcRegistry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:epc, :string, []}
  schema "lce_epc_registry" do
    field :source, :string
    field :status, :string
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:epc, :source, :status])
    |> validate_required([:epc])
  end
end
