defmodule CIA.Agent.State do
  @moduledoc false

  alias CIA.Agent
  alias CIA.Sandbox
  alias CIA.Thread
  alias CIA.Turn
  alias CIA.Workspace

  @hook_names [:before_start, :after_start, :before_stop, :after_stop]

  defstruct [
    :agent,
    :harness,
    :sandbox,
    :workspace,
    :auth,
    hooks: %{},
    env: %{},
    threads: %{},
    turns: %{}
  ]

  def new(opts) when is_list(opts) do
    with %CIA.Harness{} = harness <- Keyword.get(opts, :harness),
         %Sandbox{provider: public_sandbox} = sandbox <- Keyword.get(opts, :sandbox),
         %Workspace{} = workspace <- Keyword.get(opts, :workspace),
         {:ok, hooks} <- validate_hooks(Keyword.get(opts, :hooks, %{})),
         {:ok, env} <- validate_env(Keyword.get(opts, :env, %{})),
         {:ok, %Agent{} = agent} <-
           Agent.new(
             id: harness.id,
             pid: Keyword.get(opts, :pid),
             status: Keyword.get(opts, :status, :starting),
             harness: harness.harness,
             sandbox: public_sandbox,
             provider_ref: Keyword.get(opts, :provider_ref),
             metadata: Keyword.get(opts, :metadata, %{})
           ) do
      {:ok,
       %__MODULE__{
         agent: agent,
         harness: harness,
         sandbox: sandbox,
         workspace: workspace,
         hooks: hooks,
         auth: harness.config[:auth] || harness.config["auth"],
         env: env
       }}
    else
      _ ->
        {:error, :invalid_state}
    end
  end

  def put_agent_status(%__MODULE__{agent: %Agent{} = agent} = state, status) do
    if Agent.valid_status?(status) do
      {:ok, %__MODULE__{state | agent: %Agent{agent | status: status}}}
    else
      {:error, {:invalid_status, status}}
    end
  end

  def put_harness(%__MODULE__{} = state, harness) do
    %__MODULE__{state | harness: harness}
  end

  def put_thread(%__MODULE__{} = state, %Thread{id: id} = thread) do
    %__MODULE__{state | threads: Map.put(state.threads, id, thread)}
  end

  def put_turn(%__MODULE__{} = state, %Turn{id: id} = turn) do
    %__MODULE__{state | turns: Map.put(state.turns, id, turn)}
  end

  def get_thread(%__MODULE__{} = state, id) when is_binary(id) do
    case Map.fetch(state.threads, id) do
      {:ok, thread} -> {:ok, thread}
      :error -> {:error, {:thread_not_found, id}}
    end
  end

  def get_turn(%__MODULE__{} = state, id) when is_binary(id) do
    case Map.fetch(state.turns, id) do
      {:ok, turn} -> {:ok, turn}
      :error -> {:error, {:turn_not_found, id}}
    end
  end

  def update_turn_status(%__MODULE__{} = state, id, status) when is_binary(id) do
    with {:ok, %Turn{} = turn} <- get_turn(state, id) do
      updated_turn = %Turn{turn | status: status}
      updated_state = put_turn(state, updated_turn)
      {:ok, updated_state, updated_turn}
    end
  end

  def put_sandbox(%__MODULE__{} = state, sandbox) do
    %__MODULE__{state | sandbox: sandbox}
  end

  def put_workspace(%__MODULE__{} = state, workspace) do
    %__MODULE__{state | workspace: workspace}
  end

  defp validate_env(env) when is_map(env), do: {:ok, env}
  defp validate_env(_), do: {:error, {:invalid_env, :expected_map}}

  defp validate_hooks(nil), do: {:ok, %{}}

  defp validate_hooks(hooks) when is_map(hooks) do
    Enum.reduce_while(hooks, {:ok, %{}}, fn {hook_name, callbacks}, {:ok, acc} ->
      with :ok <- validate_hook_name(hook_name),
           :ok <- validate_callbacks(callbacks) do
        {:cont, {:ok, Map.put(acc, hook_name, callbacks)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_hooks(_), do: {:error, {:invalid_option, :hooks}}

  defp validate_hook_name(hook_name) do
    case hook_name in @hook_names do
      true -> :ok
      false -> {:error, {:invalid_hook, hook_name}}
    end
  end

  defp validate_callbacks(callbacks) when is_list(callbacks) do
    case Enum.all?(callbacks, &is_function(&1, 1)) do
      true -> :ok
      false -> {:error, {:invalid_hook_callbacks, :expected_unary_functions}}
    end
  end

  defp validate_callbacks(_), do: {:error, {:invalid_hook_callbacks, :expected_list}}
end
