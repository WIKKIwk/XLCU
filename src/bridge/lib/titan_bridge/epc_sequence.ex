defmodule TitanBridge.EpcSequence do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:prefix, :string, []}
  schema "lce_epc_sequences" do
    field(:last_value, :integer, default: 0)
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:prefix, :last_value])
    |> validate_required([:prefix])
  end
end
