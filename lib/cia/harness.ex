defmodule CIA.Harness do
  @moduledoc false

  @enforce_keys [:id, :harness]
  defstruct [:id, :harness, :cwd, config: %{}, session: %{}]

  @callback runtime_command(term()) :: {String.t(), [String.t()]}
  @callback start_session(term()) :: {:ok, term(), list()} | {:error, term()}
  @callback stop_session(term()) :: :ok | {:error, term()}
  @callback start_thread(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback submit_turn(term(), term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback steer_turn(term(), term(), term(), keyword()) :: :ok | {:error, term()}
  @callback cancel_turn(term(), term()) :: :ok | {:error, term()}

  @doc false
  def new(opts) when is_list(opts) do
    with {:ok, id} <- validate_id(Keyword.get(opts, :id)),
         {:ok, harness} <- validate_harness(Keyword.get(opts, :harness)) do
      {:ok,
       %__MODULE__{
         id: id,
         harness: harness,
         config: opts |> Keyword.drop([:id, :harness]) |> Map.new()
       }}
    end
  end

  def module_for(%__MODULE__{harness: harness}), do: module_for(harness)
  def module_for(:codex), do: {:ok, CIA.Harness.Codex}
  def module_for(module) when is_atom(module), do: {:ok, module}
  def module_for(other), do: {:error, {:invalid_harness, other}}

  def runtime_command(%{harness: harness} = state) do
    with {:ok, module} <- module_for(harness) do
      case module.runtime_command(state) do
        {command, args} when is_binary(command) and is_list(args) -> {:ok, {command, args}}
        other -> {:error, {:invalid_runtime_command, other}}
      end
    end
  end

  def start_session(%{harness: harness} = state) do
    with {:ok, module} <- module_for(harness) do
      module.start_session(state)
    end
  end

  def stop_session(%{harness: harness} = session) do
    with {:ok, module} <- module_for(harness) do
      module.stop_session(session)
    end
  end

  def start_thread(%{harness: harness} = session, opts \\ []) when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.start_thread(session, opts)
    end
  end

  def submit_turn(%{harness: harness} = session, thread_ref, input, opts \\ [])
      when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.submit_turn(session, thread_ref, input, opts)
    end
  end

  def steer_turn(%{harness: harness} = session, turn_ref, input, opts \\ [])
      when is_list(opts) do
    with {:ok, module} <- module_for(harness) do
      module.steer_turn(session, turn_ref, input, opts)
    end
  end

  def cancel_turn(%{harness: harness} = session, turn_ref) do
    with {:ok, module} <- module_for(harness) do
      module.cancel_turn(session, turn_ref)
    end
  end

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, {:invalid_id, :expected_non_empty_string}}

  defp validate_harness(nil), do: {:error, {:missing_option, :harness}}
  defp validate_harness(harness) when is_atom(harness), do: {:ok, harness}
  defp validate_harness(_), do: {:error, {:missing_option, :harness}}
end
