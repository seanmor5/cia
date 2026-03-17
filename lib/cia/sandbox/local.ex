defmodule CIA.Sandbox.Local do
  @moduledoc false

  @behaviour CIA.Sandbox

  alias CIA.Sandbox.Channel
  alias CIA.Sandbox.Local.Channel.Stdio

  defstruct [:mode, :channel, metadata: %{}]

  def start(%CIA.Sandbox{provider: :local, config: config, metadata: metadata}, opts)
      when is_list(opts) do
    opts =
      config
      |> Map.to_list()
      |> Keyword.merge(opts)
      |> Keyword.put_new(:metadata, metadata)

    mode = sandbox_mode(opts)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, channel} <- start_channel(opts) do
      {:ok, %__MODULE__{mode: mode, channel: channel, metadata: metadata}}
    end
  end

  def stop(%__MODULE__{channel: %Channel{} = channel}) do
    :ok = Channel.stop(channel)
    :ok
  end

  def exec(%__MODULE__{}, command, opts) when is_list(command) and is_list(opts) do
    with {:ok, executable, args} <- split_exec_command(command) do
      exec_opts =
        []
        |> maybe_put_exec_cd(Keyword.get(opts, :cwd))
        |> maybe_put_exec_env(Keyword.get(opts, :env, %{}))
        |> Keyword.put(:stderr_to_stdout, true)

      case System.cmd(executable, args, exec_opts) do
        {output, 0} ->
          {:ok, %{stdout: output, stderr: "", exit_code: 0}}

        {output, status} ->
          {:error, {:command_failed, %{stdout: output, stderr: "", exit_code: status}}}
      end
    end
  end

  defp sandbox_mode(opts), do: Keyword.get(opts, :mode, :workspace_write)

  defp start_channel(opts) do
    command =
      opts
      |> Keyword.fetch!(:command)
      |> normalize_runtime_command()

    env = Keyword.get(opts, :env, %{})

    case Stdio.start_link(owner: self(), command: command, env: env) do
      {:ok, pid} -> {:ok, Channel.new(Stdio, pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_exec_command([executable | args]) when is_binary(executable) do
    case resolve_executable(executable) do
      {:ok, resolved} -> {:ok, resolved, args}
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_exec_command(_), do: {:error, {:invalid_option, :command}}

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

  defp maybe_put_exec_cd(opts, nil), do: opts
  defp maybe_put_exec_cd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp maybe_put_exec_env(opts, env) when env == %{}, do: opts

  defp maybe_put_exec_env(opts, env) when is_map(env),
    do: Keyword.put(opts, :env, Map.to_list(env))

  defp normalize_runtime_command({command, args})
       when is_binary(command) and is_list(args),
       do: [command | args]

  defp normalize_runtime_command(command) when is_list(command), do: command
end
