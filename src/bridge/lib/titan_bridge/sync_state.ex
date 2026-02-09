defmodule TitanBridge.SyncState do
  import Ecto.Query
  alias TitanBridge.Repo
  alias TitanBridge.Cache.SyncState, as: State

  def get(key) when is_binary(key) do
    case Repo.get(State, key) do
      nil -> nil
      %State{value: value} -> value
    end
  end

  def put(key, value) when is_binary(key) and is_binary(value) do
    Repo.insert(%State{key: key, value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end

  def reset_all do
    Repo.delete_all(State)
    :ok
  end

  def reset(keys) when is_list(keys) do
    from(s in State, where: s.key in ^keys) |> Repo.delete_all()
    :ok
  end

  def reset(key) when is_binary(key), do: reset([key])
end
