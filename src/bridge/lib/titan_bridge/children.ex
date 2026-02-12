defmodule TitanBridge.Children do
  @moduledoc """
  OS process manager — spawns and monitors child applications via Port.

  Configured in runtime.exs with :children list. Each child has:
    name — atom identifier (:zebra, :rfid)
    cmd  — executable path (bash)
    args — command arguments (["run.sh"])
    cwd  — working directory
    env  — environment variables list

  Monitors child processes. On unexpected exit, restarts with backoff.
  Children inherit runtime environment variables from parent.
  """
  use GenServer
  require Logger

  alias TitanBridge.{ChildrenTarget, SettingsStore}

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_state) do
    if enabled?() do
      ensure_local_urls()
      children = Application.get_env(:titan_bridge, :children, [])
      state = start_children(filter_children(children))
      {:ok, state}
    else
      {:ok, %{children: %{}}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    list =
      state.children
      |> Enum.map(fn {name, child} ->
        info = Port.info(child.port) || []

        %{
          name: name,
          cmd: child.cmd,
          cwd: child.cwd,
          os_pid: info[:os_pid],
          running: is_pid(info[:connected])
        }
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) do
    case find_child(state, port) do
      {name, _child} ->
        Logger.info("[child #{name}] #{String.trim_trailing(data)}")

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) do
    case find_child(state, port) do
      {name, child} ->
        Logger.warning("[child #{name}] exited with status #{status}")
        next_state = remove_child(state, name)

        if child.restart do
          Process.send_after(self(), {:restart_child, child}, child.restart_delay_ms)
        end

        {:noreply, next_state}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:restart_child, child}, state) do
    case start_child(child) do
      {:ok, _port, entry} ->
        {:noreply, put_child(state, entry.name, entry)}

      {:error, reason} ->
        Logger.error("[child #{child.name}] restart failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp enabled? do
    case System.get_env("LCE_CHILDREN_MODE") do
      "0" -> false
      "off" -> false
      "false" -> false
      _ -> true
    end
  end

  defp filter_children(children) do
    case ChildrenTarget.list() do
      :all ->
        children

      targets ->
        Enum.filter(children, fn child ->
          name = child.name |> to_string() |> String.downcase()
          name in targets
        end)
    end
  end

  defp ensure_local_urls do
    zebra_url =
      if ChildrenTarget.enabled?("zebra") do
        System.get_env("LCE_ZEBRA_URL") ||
          local_url("LCE_ZEBRA_PORT", "18000")
      else
        nil
      end

    rfid_url =
      if ChildrenTarget.enabled?("rfid") do
        System.get_env("LCE_RFID_URL") ||
          local_url("LCE_RFID_PORT", "8787")
      else
        nil
      end

    current = SettingsStore.get()
    updates = %{}

    updates =
      if blank?(current && current.zebra_url) && zebra_url do
        Map.put(updates, :zebra_url, zebra_url)
      else
        updates
      end

    updates =
      if is_nil(rfid_url) and not blank?(current && current.rfid_url) do
        Map.put(updates, :rfid_url, nil)
      else
        updates
      end

    updates =
      if blank?(current && current.rfid_url) && rfid_url do
        Map.put(updates, :rfid_url, rfid_url)
      else
        updates
      end

    if map_size(updates) > 0 do
      SettingsStore.upsert(updates)
    end
  end

  defp local_url(env_key, default_port) do
    port = System.get_env(env_key) || default_port
    "http://127.0.0.1:#{port}"
  end

  defp blank?(value) do
    case value do
      nil -> true
      "" -> true
      v when is_binary(v) -> String.trim(v) == ""
      _ -> false
    end
  end

  defp start_children(children) do
    Enum.reduce(children, %{children: %{}}, fn child, acc ->
      case start_child(child) do
        {:ok, _port, entry} ->
          put_child(acc, entry.name, entry)

        {:error, reason} ->
          Logger.error("[child #{child.name}] failed to start: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_child(%{cmd: cmd} = child) when is_binary(cmd) or is_list(cmd) do
    # cmd charlist yoki binary bo'lishi mumkin (restart da charlist keladi)
    cmd_bin = if is_list(cmd), do: to_string(cmd), else: cmd
    args = child.args || []
    cwd = child[:cwd]

    # args ham charlist yoki binary bo'lishi mumkin
    args_bin = Enum.map(args, fn
      a when is_list(a) -> to_string(a)
      a -> a
    end)

    cond do
      cwd && is_binary(cwd) && !File.dir?(cwd) ->
        {:error, {:invalid_cwd, cwd}}

      match?([script | _], args_bin) && cwd && is_binary(hd(args_bin)) &&
          !File.exists?(Path.join(to_string(cwd), hd(args_bin))) ->
        {:error, {:missing_script, Path.join(to_string(cwd), hd(args_bin))}}

      true ->
        :ok
    end
    |> case do
      {:error, _} = err ->
        err

      _ ->
        charlist_args = Enum.map(args_bin, &to_charlist/1)
        charlist_cmd = to_charlist(cmd_bin)

        opts = [
          :binary,
          :exit_status,
          {:args, charlist_args}
        ]

        cwd_str = if cwd, do: to_string(cwd), else: nil
        opts = if cwd_str, do: opts ++ [{:cd, to_charlist(cwd_str)}], else: opts

        opts =
          if child[:env] do
            env =
              Enum.map(child.env, fn {key, value} ->
                {to_charlist(to_string(key)), to_charlist(to_string(value))}
              end)

            opts ++ [{:env, env}]
          else
            opts
          end

        port = Port.open({:spawn_executable, charlist_cmd}, opts)

        {:ok, port,
         %{
           name: child.name,
           port: port,
           cmd: cmd_bin,
           args: args_bin,
           cwd: cwd_str,
           env: child[:env],
           restart: Map.get(child, :restart, true),
           restart_delay_ms: Map.get(child, :restart_delay_ms, 1500)
         }}
    end
  end

  defp start_child(_), do: {:error, :invalid_child}

  defp find_child(state, port) do
    Enum.find(state.children, fn {_name, child} -> child.port == port end)
  end

  defp remove_child(state, name) do
    %{state | children: Map.delete(state.children, name)}
  end

  defp put_child(state, name, entry) do
    %{state | children: Map.put(state.children, name, entry)}
  end
end
