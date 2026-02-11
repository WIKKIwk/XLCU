defmodule TitanBridge.ChildrenTarget do
  @moduledoc false

  @valid_targets ["zebra", "rfid"]

  def list do
    case System.get_env("LCE_CHILDREN_TARGET") do
      nil ->
        :all

      "" ->
        :all

      "all" ->
        :all

      raw ->
        targets =
          raw
          |> String.split([",", " "], trim: true)
          |> Enum.map(&String.downcase/1)
          |> Enum.filter(&(&1 in @valid_targets))
          |> Enum.uniq()

        if targets == [], do: :all, else: targets
    end
  end

  def enabled?(target) when is_atom(target), do: enabled?(Atom.to_string(target))

  def enabled?(target) when is_binary(target) do
    normalized = String.downcase(target)

    case list() do
      :all -> true
      targets -> normalized in targets
    end
  end
end
