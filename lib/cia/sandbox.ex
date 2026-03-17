defmodule CIA.Sandbox do
  @moduledoc """
  A first-class sandbox handle.

  Sandboxes represent the compute or runtime layer where code can execute,
  independent from any specific workspace or agent session.
  """

  @enforce_keys [:id, :provider]
  defstruct [:id, :provider, config: %{}, metadata: %{}]

  @callback start(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback stop(term()) :: :ok | {:error, term()}
  @callback exec(term(), [String.t()], keyword()) :: {:ok, term()} | {:error, term()}

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, provider} <- validate_provider(Keyword.get(opts, :provider)),
         {:ok, metadata} <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         provider: provider,
         config: opts |> Keyword.drop([:id, :provider, :metadata]) |> Map.new(),
         metadata: metadata
       }}
    end
  end

  def module_for(%__MODULE__{provider: provider}), do: module_for(provider)
  def module_for(:local), do: {:ok, CIA.Sandbox.Local}
  def module_for(:sprite), do: {:ok, CIA.Sandbox.Sprite}
  def module_for(%module{}), do: {:ok, module}
  def module_for(module) when is_atom(module), do: {:ok, module}
  def module_for(other), do: {:error, {:invalid_sandbox, other}}

  def start(sandbox, opts \\ []) do
    with {:ok, module} <- module_for(sandbox) do
      module.start(sandbox, opts)
    end
  end

  def exec(sandbox, command, opts \\ []) do
    with {:ok, module} <- module_for(sandbox),
         true <- function_exported?(module, :exec, 3) do
      module.exec(sandbox, command, opts)
    else
      false -> {:error, {:unsupported_sandbox_operation, :exec}}
      {:error, _reason} = error -> error
    end
  end

  def stop(sandbox) do
    with {:ok, module} <- module_for(sandbox) do
      module.stop(sandbox)
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
