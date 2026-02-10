defmodule TitanBridge.Cache.SyncState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, []}
  schema "lce_sync_state" do
    field(:value, :string)
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
  end
end
