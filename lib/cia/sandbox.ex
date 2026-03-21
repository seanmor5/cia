defmodule CIA.Sandbox do
  @moduledoc """
  A first-class sandbox runtime API.

  Sandboxes represent the compute or runtime layer where code can execute,
  independent from any specific workspace or agent session.

  `cmd/4` is the public entry point for running one-shot commands against a
  live sandbox runtime.
  """

  @enforce_keys [:id, :provider]
  defstruct [:id, :provider, config: %{}, metadata: %{}]

  @callback start(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback stop(term()) :: :ok | {:error, term()}
  @callback exec(term(), [String.t()], keyword()) :: {:ok, term()} | {:error, term()}
  @callback normalize_config(map()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks normalize_config: 1

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider)),
         {:ok, metadata} <- validate_metadata(Keyword.get(opts, :metadata, %{})),
         {:ok, config} <-
           opts
           |> Keyword.drop([:id, :provider, :metadata])
           |> Map.new()
           |> normalize_config(provider) do
      {:ok,
       %__MODULE__{
         id: id,
         provider: provider,
         config: config,
         metadata: metadata
       }}
    end
  end

  @doc false
  def module_for(%__MODULE__{provider: provider}), do: module_for(provider)
  def module_for(:local), do: {:ok, CIA.Sandbox.Local}
  def module_for(:sprite), do: {:ok, CIA.Sandbox.Sprite}
  def module_for(:sprites), do: {:ok, CIA.Sandbox.Sprite}
  def module_for(%module{}), do: {:ok, module}
  def module_for(module) when is_atom(module), do: {:ok, module}
  def module_for(other), do: {:error, {:invalid_sandbox, other}}

  @doc false
  def start(sandbox, opts \\ []) do
    with {:ok, module} <- module_for(sandbox) do
      module.start(sandbox, opts)
    end
  end

  @doc """
  Runs a one-shot command inside a live sandbox runtime.

  This mirrors the shape of `System.cmd/3`, but runs against a CIA sandbox
  runtime instead of the local OS process environment.

  Supported options currently include:

  - `:cd`
  - `:env`
  - `:into`
  - `:stderr_to_stdout`
  - `:timeout`

  On command execution, returns `{output, exit_status}`. Sandbox transport or
  provider failures are returned as `{:error, reason}`.
  """
  def cmd(sandbox, command, args \\ [], opts \\ [])
      when is_binary(command) and is_list(args) and is_list(opts) do
    exec_opts = normalize_cmd_opts(opts)

    case exec(sandbox, [command | args], exec_opts) do
      {:ok, output} ->
        {format_cmd_output(output, opts), output.exit_code}

      {:error, {:command_failed, output}} ->
        {format_cmd_output(output, opts), output.exit_code}

      {:error, {:unsupported_sandbox_operation, :exec}} ->
        {:error, {:unsupported_sandbox_operation, :cmd}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def exec(sandbox, command, opts \\ []) do
    with {:ok, module} <- module_for(sandbox),
         true <- function_exported?(module, :exec, 3) do
      module.exec(sandbox, command, opts)
    else
      false -> {:error, {:unsupported_sandbox_operation, :exec}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def stop(sandbox) do
    with {:ok, module} <- module_for(sandbox) do
      module.stop(sandbox)
    end
  end

  defp normalize_cmd_opts(opts) when is_list(opts) do
    opts
    |> maybe_put_cwd()
    |> maybe_normalize_env()
  end

  defp maybe_put_cwd(opts) do
    case Keyword.fetch(opts, :cd) do
      {:ok, cwd} -> Keyword.put(opts, :cwd, cwd)
      :error -> opts
    end
  end

  defp maybe_normalize_env(opts) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} -> Keyword.put(opts, :env, normalize_env(env))
      :error -> opts
    end
  end

  defp normalize_env(env) when is_map(env), do: env
  defp normalize_env(env) when is_list(env), do: Map.new(env)

  defp format_cmd_output(output, opts) when is_map(output) and is_list(opts) do
    stderr_to_stdout? = Keyword.get(opts, :stderr_to_stdout, false)

    stdout =
      case stderr_to_stdout? do
        true -> Map.get(output, :stdout, "") <> Map.get(output, :stderr, "")
        false -> Map.get(output, :stdout, "")
      end

    collect_into(stdout, Keyword.get(opts, :into, ""))
  end

  defp collect_into(output, into) when is_binary(into), do: into <> output

  defp collect_into(output, into) do
    {acc, collector} = Collectable.into(into)
    acc = collector.(acc, {:cont, output})
    collector.(acc, :done)
  end

  defp normalize_config(config, provider) when is_map(config) do
    with {:ok, module} <- module_for(provider) do
      case Code.ensure_loaded(module) do
        {:module, _module} ->
          case function_exported?(module, :normalize_config, 1) do
            true -> module.normalize_config(config)
            false -> {:ok, config}
          end

        {:error, _reason} ->
          {:ok, config}
      end
    end
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_provider(nil), do: {:error, {:missing_option, :provider}}
  defp validate_provider(provider) when is_atom(provider), do: {:ok, provider}
  defp validate_provider(_), do: {:error, {:missing_option, :provider}}

  defp validate_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp validate_metadata(_), do: {:error, {:invalid_metadata, :expected_map}}
end
