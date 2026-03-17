defmodule CIA.Agent do
  @moduledoc false

  @statuses [:starting, :running, :stopping, :stopped, :failed]

  @enforce_keys [:id, :status, :harness, :sandbox]
  defstruct [:id, :pid, :status, :harness, :sandbox, :provider_ref, metadata: %{}]

  @doc false
  def valid_status?(status), do: status in @statuses

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, harness} <- validate_component(:harness, Keyword.get(opts, :harness)),
         {:ok, sandbox} <- validate_component(:sandbox, Keyword.get(opts, :sandbox)),
         {:ok, status} <- validate_status(Keyword.get(opts, :status, :starting)),
         {:ok, metadata} <- validate_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         pid: Keyword.get(opts, :pid),
         status: status,
         harness: harness,
         sandbox: sandbox,
         provider_ref: Keyword.get(opts, :provider_ref),
         metadata: metadata
       }}
    end
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_component(field, nil), do: {:error, {:missing_option, field}}
  defp validate_component(_field, value) when is_atom(value), do: {:ok, value}
  defp validate_component(field, _), do: {:error, {:invalid_option, field}}

  defp validate_status(status) do
    if valid_status?(status) do
      {:ok, status}
    else
      {:error, {:invalid_status, status}}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: {:ok, metadata}
  defp validate_metadata(_), do: {:error, {:invalid_metadata, :expected_map}}
end
