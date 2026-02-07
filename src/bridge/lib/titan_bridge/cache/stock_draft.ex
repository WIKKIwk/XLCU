defmodule TitanBridge.Cache.StockDraft do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:name, :docstatus, :purpose, :posting_date, :posting_time, :from_warehouse, :to_warehouse, :modified, :data, :inserted_at, :updated_at]}
  @primary_key {:name, :string, []}
  schema "lce_stock_drafts" do
    field :docstatus, :integer
    field :purpose, :string
    field :posting_date, :string
    field :posting_time, :string
    field :from_warehouse, :string
    field :to_warehouse, :string
    field :modified, :string
    field :data, :map
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:name, :docstatus, :purpose, :posting_date, :posting_time, :from_warehouse, :to_warehouse, :modified, :data])
    |> validate_required([:name])
  end
end
