defmodule CIA.Sandbox.Local.Channel.Stdio do
  @moduledoc false

  @behaviour CIA.Sandbox.Channel

  use GenServer

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def send(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:send, data})
  end

  @impl true
  def set_owner(pid, owner) when is_pid(pid) and is_pid(owner) do
    GenServer.call(pid, {:set_owner, owner})
  end

  @impl true
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.stop(pid, :normal, timeout)
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})

    with {:ok, executable, args} <- split_command(command),
         {:ok, port_opts} <- port_opts(owner, executable, args, cwd, env),
         port <- Port.open({:spawn_executable, executable}, port_opts) do
      {:ok, %{owner: owner, port: port}}
    end
  end

  @impl true
  def handle_call({:send, data}, _from, %{port: port} = state) do
    case Port.command(port, data) do
      true -> {:reply, :ok, state}
      _ -> {:reply, {:error, :channel_send_failed}, state}
    end
  end

  def handle_call({:set_owner, owner}, _from, state) do
    {:reply, :ok, %{state | owner: owner}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{owner: owner, port: port} = state) do
    Kernel.send(owner, {:cia_sandbox_channel, self(), {:data, data}})
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{owner: owner, port: port} = state) do
    Kernel.send(owner, {:cia_sandbox_channel, self(), {:exit, {:local_exec_exit, status}}})
    {:stop, {:local_exec_exit, status}, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp split_command([executable | args]) when is_binary(executable) do
    case resolve_executable(executable) do
      {:ok, resolved} -> {:ok, resolved, args}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_command(_), do: {:error, {:invalid_option, :command}}

  defp resolve_executable(executable) when is_binary(executable) do
    cond do
      executable == "" ->
        {:error, {:command_not_found, executable}}

      String.contains?(executable, "/") and File.exists?(executable) ->
        {:ok, executable}

      true ->
        case System.find_executable(executable) do
          nil -> {:error, {:command_not_found, executable}}
          resolved -> {:ok, resolved}
        end
    end
  end

  defp port_opts(owner, executable, args, cwd, env) do
    opts =
      [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        :stderr_to_stdout,
        args: args
      ]
      |> maybe_put_cd(cwd)
      |> maybe_put_env(env)

    if is_binary(executable) do
      {:ok, opts}
    else
      Kernel.send(
        owner,
        {:cia_sandbox_channel, self(), {:exit, {:invalid_executable, executable}}}
      )

      {:error, {:invalid_executable, executable}}
    end
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp maybe_put_env(opts, env) when env == %{}, do: opts

  defp maybe_put_env(opts, env) when is_map(env) do
    Keyword.put(
      opts,
      :env,
      Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
    )
  end
end
