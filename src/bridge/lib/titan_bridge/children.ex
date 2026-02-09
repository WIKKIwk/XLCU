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
  Children inherit LCE_SIMULATE_DEVICES and LCE_CHILDREN_MODE from parent.
  """
  use GenServer
  require Logger

  alias TitanBridge.SettingsStore

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
    list = state.children
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
    case child_targets() do
      :all -> children
      targets ->
        Enum.filter(children, fn child ->
          name = child.name |> to_string() |> String.downcase()
          name in targets
        end)
    end
  end

  defp child_targets do
    case System.get_env("LCE_CHILDREN_TARGET") do
      nil -> :all
      "" -> :all
      "all" -> :all
      raw ->
        targets =
          raw
          |> String.split([",", " "], trim: true)
          |> Enum.map(&String.downcase/1)
          |> Enum.filter(&(&1 in ["zebra", "rfid"]))

        if targets == [], do: :all, else: targets
    end
  end

  defp ensure_local_urls do
    zebra_url = System.get_env("LCE_ZEBRA_URL")
      || local_url("LCE_ZEBRA_PORT", "18000")
    rfid_url = System.get_env("LCE_RFID_URL")
      || local_url("LCE_RFID_PORT", "8787")

    current = SettingsStore.get()
    updates = %{}

    updates =
      if blank?(current && current.zebra_url) && zebra_url do
        Map.put(updates, :zebra_url, zebra_url)
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

  defp start_child(%{cmd: cmd} = child) when is_binary(cmd) do
    args = child.args || []
    cwd = child.cwd
    cond do
      cwd && !File.dir?(cwd) ->
        {:error, {:invalid_cwd, cwd}}
      match?([script | _], args) && cwd && is_binary(hd(args)) && !File.exists?(Path.join(cwd, hd(args))) ->
        {:error, {:missing_script, Path.join(cwd, hd(args))}}
      true ->
        :ok
    end
    |> case do
      {:error, _} = err ->
        err
      _ ->
        args = Enum.map(args, &to_charlist/1)
        cmd = to_charlist(cmd)

        opts = [
          :binary,
          :exit_status,
          {:args, args}
        ]
        opts = if child.cwd, do: opts ++ [{:cd, to_charlist(child.cwd)}], else: opts
        opts =
          if child.env do
            env = Enum.map(child.env, fn {key, value} ->
              {to_charlist(key), to_charlist(value)}
            end)
            opts ++ [{:env, env}]
          else
            opts
          end

        port = Port.open({:spawn_executable, cmd}, opts)
        {:ok, port, %{
          name: child.name,
          port: port,
          cmd: cmd,
          cwd: child.cwd,
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
