defmodule CIA.Workspace do
  @moduledoc false

  alias CIA.Sandbox

  @enforce_keys [:id, :sandbox, :root]
  defstruct [:id, :sandbox, :root, kind: :directory, config: %{}, metadata: %{}]

  @callback materialize(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback cleanup(term(), term()) :: :ok | {:error, term()}

  @doc false
  def new(%Sandbox{} = sandbox, opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, root} <- validate_root(Keyword.get(opts, :root)),
         {:ok, kind} <- validate_kind(Keyword.get(opts, :kind, :directory)),
         {:ok, metadata} <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         sandbox: sandbox,
         root: root,
         kind: kind,
         config: opts |> Keyword.drop([:id, :root, :kind, :metadata]) |> Map.new(),
         metadata: metadata
       }}
    end
  end

  def module_for(%__MODULE__{kind: :directory}), do: {:ok, CIA.Workspace.Directory}
  def module_for(%__MODULE__{kind: kind}), do: {:error, {:unsupported_workspace_kind, kind}}
  def module_for(_), do: {:error, {:invalid_workspace, :expected_workspace_struct}}

  def materialize(%__MODULE__{} = workspace, sandbox) do
    with {:ok, module} <- module_for(workspace) do
      module.materialize(workspace, sandbox)
    end
  end

  def cleanup(%__MODULE__{} = workspace, sandbox) do
    with {:ok, module} <- module_for(workspace) do
      module.cleanup(workspace, sandbox)
    end
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_root(root) when is_binary(root) and byte_size(root) > 0, do: {:ok, root}
  defp validate_root(_), do: {:error, {:missing_option, :root}}

  defp validate_kind(:directory), do: {:ok, :directory}
  defp validate_kind(kind) when is_atom(kind), do: {:error, {:unsupported_workspace_kind, kind}}
  defp validate_kind(_), do: {:error, {:invalid_option, :kind}}

  defp validate_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp validate_metadata(_), do: {:error, {:invalid_metadata, :expected_map}}
end
