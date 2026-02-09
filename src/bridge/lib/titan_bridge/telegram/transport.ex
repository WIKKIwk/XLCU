defmodule TitanBridge.Telegram.Transport do
  @moduledoc """
  Thin Telegram Bot API wrapper shared by bridge bots.
  """

  require Logger

  @base_url "https://api.telegram.org/bot"

  def get_updates(token, offset, timeout_sec, opts \\ []) do
    url = "#{@base_url}#{token}/getUpdates?timeout=#{timeout_sec}&offset=#{offset}"

    case Finch.build(:get, url) |> Finch.request(TitanBridgeFinch, request_opts(opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) -> {:ok, updates}
          {:ok, _} -> {:error, :invalid_response}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(token, chat_id, text, reply_markup \\ nil, opts \\ []) do
    payload = %{"chat_id" => chat_id, "text" => text}
    payload = if reply_markup, do: Map.put(payload, "reply_markup", reply_markup), else: payload

    case post_json(token, "sendMessage", payload, opts) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => message_id}}} ->
        message_id

      {:ok, _} ->
        nil

      {:error, reason} ->
        log_error(opts, "sendMessage failed: #{inspect(reason)}")
        nil
    end
  end

  def edit_message(token, chat_id, message_id, text, reply_markup \\ nil, opts \\ []) do
    payload = %{"chat_id" => chat_id, "message_id" => message_id, "text" => text}
    payload = if reply_markup, do: Map.put(payload, "reply_markup", reply_markup), else: payload

    case post_json(token, "editMessageText", payload, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error(opts, "editMessageText failed: #{inspect(reason)}")
        :ok
    end
  end

  def answer_callback(token, callback_id, text \\ nil, opts \\ []) do
    payload = %{"callback_query_id" => callback_id}
    payload = if text, do: Map.put(payload, "text", text), else: payload

    case post_json(token, "answerCallbackQuery", payload, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error(opts, "answerCallbackQuery failed: #{inspect(reason)}")
        :ok
    end
  end

  def answer_inline_query(token, query_id, results, opts \\ []) do
    payload = %{
      "inline_query_id" => query_id,
      "results" => results,
      "cache_time" => 1,
      "is_personal" => true
    }

    case post_json(token, "answerInlineQuery", payload, opts) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        log_error(opts, "answerInlineQuery failed: #{inspect(reason)}")
        :ok
    end
  end

  def delete_message(token, chat_id, message_id, opts \\ []) do
    payload = %{"chat_id" => chat_id, "message_id" => message_id}

    case post_json(token, "deleteMessage", payload, opts) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp post_json(token, method, payload, opts) do
    url = "#{@base_url}#{token}/#{method}"
    body = Jason.encode!(payload)

    case Finch.build(:post, url, [{"content-type", "application/json"}], body)
         |> Finch.request(TitanBridgeFinch, request_opts(opts)) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{}}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_opts(opts) do
    case Keyword.get(opts, :receive_timeout) do
      nil -> []
      timeout -> [receive_timeout: timeout]
    end
  end

  defp log_error(opts, message) do
    case Keyword.get(opts, :log_level, :warning) do
      :debug -> Logger.debug(message)
      :info -> Logger.info(message)
      :error -> Logger.error(message)
      _ -> Logger.warning(message)
    end
  end
end
