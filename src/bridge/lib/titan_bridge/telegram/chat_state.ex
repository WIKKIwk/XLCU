defmodule TitanBridge.Telegram.ChatState do
  @moduledoc """
  Shared ETS helpers for Telegram bots.

  Keeps per-chat state, temporary flow data, and Telegram update offset.
  """

  @doc """
  Ensures both ETS tables exist (idempotent).
  """
  def init_tables!(state_table, temp_table) do
    _ = ensure_table(state_table)
    _ = ensure_table(temp_table)
    :ok
  end

  def set_state(state_table, chat_id, state) do
    :ets.insert(state_table, {chat_id, state})
    :ok
  end

  def get_state(state_table, chat_id, default \\ "none") do
    case :ets.lookup(state_table, chat_id) do
      [{^chat_id, state}] -> state
      _ -> default
    end
  end

  def put_temp(temp_table, chat_id, key, value) do
    :ets.insert(temp_table, {{chat_id, key}, value})
    :ok
  end

  def get_temp(temp_table, chat_id, key) do
    case :ets.lookup(temp_table, {chat_id, key}) do
      [{{^chat_id, ^key}, value}] -> value
      _ -> nil
    end
  end

  def delete_temp(temp_table, chat_id, key) do
    :ets.delete(temp_table, {chat_id, key})
    :ok
  end

  def clear_temp(temp_table, chat_id) do
    :ets.match_delete(temp_table, {{chat_id, :_}, :_})
    :ok
  end

  def get_offset(temp_table, default \\ 0) do
    case :ets.lookup(temp_table, :offset) do
      [{:offset, val}] -> val
      _ -> default
    end
  end

  def set_offset(temp_table, %{"update_id" => id}) do
    :ets.insert(temp_table, {:offset, id + 1})
    :ok
  end

  def set_offset(_temp_table, _update), do: :ok

  defp ensure_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined -> :ets.new(table_name, [:named_table, :set, :public])
      _tid -> table_name
    end
  end
end
