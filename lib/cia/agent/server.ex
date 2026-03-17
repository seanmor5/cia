defmodule CIA.Agent.Server do
  @moduledoc false

  use GenServer

  defstruct [:state, subscribers: %{}]

  alias CIA.Agent
  alias CIA.Agent.State
  alias CIA.Harness
  alias CIA.Sandbox
  alias CIA.Thread
  alias CIA.Turn
  alias CIA.Workspace

  @doc false
  def start_link(opts) when is_list(opts) do
    {agent_opts, server_opts} =
      Keyword.split(opts, [
        :id,
        :harness,
        :sandbox,
        :status,
        :provider_ref,
        :metadata,
        :auth,
        :hooks,
        :workspace,
        :env
      ])

    with {:ok, %State{} = state} <- State.new(agent_opts) do
      GenServer.start_link(__MODULE__, state, server_opts)
    end
  end

  @doc false
  def agent(server), do: GenServer.call(server, :agent)

  @doc false
  def subscribe(server, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @doc false
  def turn(server, turn_or_id), do: GenServer.call(server, {:turn, turn_id(turn_or_id)})

  @doc false
  def set_status(server, status), do: GenServer.call(server, {:set_status, status})

  @doc false
  def start_thread(server, opts \\ []), do: GenServer.call(server, {:start_thread, opts})

  @doc false
  def submit_turn(server, thread_or_id, input, opts \\ []),
    do: GenServer.call(server, {:submit_turn, thread_or_id, input, opts})

  @doc false
  def steer_turn(server, turn_or_id, input, opts \\ []),
    do: GenServer.call(server, {:steer_turn, turn_or_id, input, opts})

  @doc false
  def cancel_turn(server, turn_or_id), do: GenServer.call(server, {:cancel_turn, turn_or_id})

  @doc false
  def stop(server, timeout \\ :infinity), do: GenServer.stop(server, :normal, timeout)

  @impl true
  def init(%State{} = state) do
    state = put_agent_pid(state, self())

    with {:ok, started_state} <- start_runtime(state),
         {:ok, running_state} <- State.put_agent_status(started_state, :running) do
      _ =
        run_after_hooks(
          running_state,
          :after_start,
          hook_context(running_state, %{result: {:ok, running_state.agent}})
        )

      {:ok, %__MODULE__{state: running_state}}
    else
      {:error, %State{} = failed_state, reason} = error ->
        _ =
          run_after_hooks(
            failed_state,
            :after_start,
            hook_context(failed_state, %{result: error})
          )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        :agent,
        _from,
        %__MODULE__{state: %State{agent: %Agent{} = agent}} = server_state
      ) do
    {:reply, agent, server_state}
  end

  def handle_call({:subscribe, subscriber}, _from, %__MODULE__{} = server_state) do
    {:reply, :ok, add_subscriber(server_state, subscriber)}
  end

  def handle_call({:turn, id}, _from, %__MODULE__{state: %State{} = state} = server_state) do
    {:reply, State.get_turn(state, id), server_state}
  end

  def handle_call(
        {:set_status, status},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    case State.put_agent_status(state, status) do
      {:ok, %State{agent: %Agent{} = agent} = updated_state} ->
        {:reply, {:ok, agent}, put_state(server_state, updated_state)}

      {:error, {:invalid_status, _} = reason} ->
        {:reply, {:error, reason}, server_state}
    end
  end

  def handle_call(
        {:start_thread, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, thread_ref} <- Harness.start_thread(state.harness, opts) do
      thread =
        Thread.new(
          id: thread_ref.id,
          agent_id: state.agent.id,
          provider_ref: thread_ref,
          status: :active,
          metadata: Keyword.get(opts, :metadata, %{})
        )

      updated_state = State.put_thread(state, thread)
      {:reply, {:ok, thread}, put_state(server_state, updated_state)}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:submit_turn, thread_or_id, input, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    opts = maybe_put_default_sandbox_policy(opts, state)

    with {:ok, %Thread{} = thread} <- resolve_thread(state, thread_or_id),
         {:ok, turn_ref} <- Harness.submit_turn(state.harness, thread.provider_ref, input, opts) do
      updated_thread = %Thread{thread | status: :busy}

      turn =
        Turn.new(
          id: turn_ref.id,
          thread_id: updated_thread.id,
          provider_ref: turn_ref,
          status: :running,
          metadata: Keyword.get(opts, :metadata, %{})
        )

      updated_state =
        state
        |> State.put_thread(updated_thread)
        |> State.put_turn(turn)

      {:reply, {:ok, turn}, put_state(server_state, updated_state)}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:steer_turn, turn_or_id, input, opts},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, turn} <- resolve_turn(state, turn_or_id),
         :ok <- Harness.steer_turn(state.harness, turn.provider_ref, input, opts) do
      {:reply, :ok, server_state}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  def handle_call(
        {:cancel_turn, turn_or_id},
        _from,
        %__MODULE__{state: %State{} = state} = server_state
      ) do
    with {:ok, %Turn{} = turn} <- resolve_turn(state, turn_or_id),
         :ok <- Harness.cancel_turn(state.harness, turn.provider_ref),
         {:ok, updated_state, updated_turn} <-
           State.update_turn_status(state, turn.id, :cancelled),
         {:ok, %Thread{} = thread} <- State.get_thread(updated_state, turn.thread_id) do
      final_state = State.put_thread(updated_state, %Thread{thread | status: :active})
      {:reply, {:ok, updated_turn}, put_state(server_state, final_state)}
    else
      {:error, _reason} = error -> {:reply, error, server_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = server_state) do
    {:noreply, unsubscribe(server_state, pid)}
  end

  def handle_info({:cia_harness, harness, payload}, %__MODULE__{} = server_state) do
    broadcast(server_state, {:harness, harness, payload})
    {:noreply, server_state}
  end

  @impl true
  def terminate(
        reason,
        %__MODULE__{state: %State{} = state}
      ) do
    _ = run_before_hooks(state, :before_stop, hook_context(state, %{reason: reason}))

    %State{sandbox: sandbox, workspace: workspace, harness: harness} = state

    if harness != nil and harness.session != %{} do
      _ = Harness.stop_session(harness)
    end

    if workspace != nil and sandbox != nil do
      _ = Workspace.cleanup(workspace, sandbox)
    end

    if sandbox != nil do
      _ = Sandbox.stop(sandbox)
    end

    _ =
      run_after_hooks(
        state,
        :after_stop,
        hook_context(state, %{reason: reason, result: :ok})
      )

    :ok
  end

  defp start_runtime(%State{} = state) do
    with {:ok, command} <- Harness.runtime_command(state),
         {:ok, sandbox} <- Sandbox.start(state.sandbox, command: command, env: state.env) do
      sandbox_state = State.put_sandbox(state, sandbox)

      with :ok <- run_before_hooks(sandbox_state, :before_start, hook_context(sandbox_state)),
           {:ok, workspace} <- Workspace.materialize(state.workspace, sandbox) do
        runtime_state = State.put_workspace(sandbox_state, workspace)

        case Harness.start_session(runtime_state) do
          {:ok, harness, _events} ->
            {:ok, State.put_harness(runtime_state, harness)}

          {:error, reason} ->
            failed_state = put_agent_status(runtime_state, :failed)
            cleanup_runtime(failed_state)
            {:error, failed_state, reason}
        end
      else
        {:error, reason} ->
          failed_state = put_agent_status(sandbox_state, :failed)
          cleanup_runtime(failed_state)
          {:error, failed_state, reason}
      end
    else
      {:error, reason} ->
        failed_state = put_agent_status(state, :failed)
        {:error, failed_state, reason}
    end
  end

  defp resolve_thread(%State{} = state, thread_or_id) do
    State.get_thread(state, thread_id(thread_or_id))
  end

  defp resolve_turn(%State{} = state, turn_or_id) do
    State.get_turn(state, turn_id(turn_or_id))
  end

  defp thread_id(%Thread{id: id}), do: id
  defp thread_id(id) when is_binary(id), do: id

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(id) when is_binary(id), do: id

  defp run_before_hooks(%State{} = state, hook_name, context) when is_atom(hook_name) do
    state.hooks
    |> Map.get(hook_name, [])
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {hook, index}, :ok ->
      case invoke_hook(hook, context) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, normalize_before_hook_error(hook_name, index, reason)}}
      end
    end)
  end

  defp run_after_hooks(%State{} = state, hook_name, context) when is_atom(hook_name) do
    state.hooks
    |> Map.get(hook_name, [])
    |> Enum.with_index(1)
    |> Enum.each(fn {hook, _index} ->
      case invoke_hook(hook, context) do
        :ok ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end)

    :ok
  end

  defp hook_context(%State{} = state, extra \\ %{}) when is_map(extra) do
    Map.merge(
      %{
        agent: state.agent,
        harness: state.harness,
        sandbox: state.sandbox,
        workspace: state.workspace,
        env: state.env
      },
      extra
    )
  end

  defp invoke_hook(hook, context) when is_function(hook, 1) and is_map(context) do
    try do
      case hook.(context) do
        :ok -> :ok
        other -> {:error, {:invalid_return, other}}
      end
    rescue
      error -> {:error, {:exception, error, __STACKTRACE__}}
    catch
      kind, reason -> {:error, {:throw, kind, reason}}
    end
  end

  defp normalize_before_hook_error(hook_name, index, {:invalid_return, other}) do
    {:hook_failed, hook_name, index, other}
  end

  defp normalize_before_hook_error(hook_name, index, {:exception, error, stacktrace}) do
    {:hook_exception, hook_name, index, error, stacktrace}
  end

  defp normalize_before_hook_error(hook_name, index, {:throw, kind, reason}) do
    {:hook_throw, hook_name, index, kind, reason}
  end

  defp put_agent_pid(%State{agent: %Agent{} = agent} = state, pid) when is_pid(pid) do
    %State{state | agent: %Agent{agent | pid: pid}}
  end

  defp put_agent_status(%State{} = state, status) do
    case State.put_agent_status(state, status) do
      {:ok, updated_state} -> updated_state
      {:error, _reason} -> state
    end
  end

  defp cleanup_runtime(%State{workspace: workspace, sandbox: sandbox}) do
    if workspace != nil and sandbox != nil do
      _ = Workspace.cleanup(workspace, sandbox)
    end

    if sandbox != nil do
      _ = Sandbox.stop(sandbox)
    end

    :ok
  end

  defp maybe_put_default_sandbox_policy(opts, state) when is_list(opts) do
    case Keyword.has_key?(opts, :sandbox_policy) do
      true ->
        opts

      false ->
        case sandbox_policy(state) do
          nil -> opts
          policy -> Keyword.put(opts, :sandbox_policy, policy)
        end
    end
  end

  defp sandbox_policy(%State{sandbox: %{mode: :workspace_write}, workspace: %{root: root}})
       when is_binary(root) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [root],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp sandbox_policy(%State{sandbox: %{mode: :read_only}}) do
    %{
      "type" => "readOnly",
      "networkAccess" => false
    }
  end

  defp sandbox_policy(%State{sandbox: %{mode: :danger_full_access}}) do
    %{
      "type" => "dangerFullAccess",
      "networkAccess" => false
    }
  end

  defp sandbox_policy(%State{sandbox: %{mode: :full_access}}) do
    %{
      "type" => "dangerFullAccess",
      "networkAccess" => false
    }
  end

  defp sandbox_policy(%State{sandbox: %{mode: "workspace-write"}, workspace: %{root: root}})
       when is_binary(root) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [root],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp sandbox_policy(%State{sandbox: %{mode: "read-only"}}) do
    %{"type" => "readOnly", "networkAccess" => false}
  end

  defp sandbox_policy(%State{sandbox: %{mode: "danger-full-access"}}) do
    %{"type" => "dangerFullAccess", "networkAccess" => false}
  end

  defp sandbox_policy(%State{sandbox: %{mode: "dangerFullAccess"}}) do
    %{"type" => "dangerFullAccess", "networkAccess" => false}
  end

  defp sandbox_policy(%State{sandbox: %{mode: "readOnly"}}) do
    %{"type" => "readOnly", "networkAccess" => false}
  end

  defp sandbox_policy(%State{sandbox: %{mode: "workspaceWrite"}, workspace: %{root: root}})
       when is_binary(root) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [root],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp sandbox_policy(_), do: nil

  defp put_state(%__MODULE__{} = server_state, %State{} = state) do
    %__MODULE__{server_state | state: state}
  end

  defp add_subscriber(%__MODULE__{subscribers: subscribers} = server_state, pid)
       when is_pid(pid) do
    case Map.has_key?(subscribers, pid) do
      true ->
        server_state

      false ->
        %__MODULE__{server_state | subscribers: Map.put(subscribers, pid, Process.monitor(pid))}
    end
  end

  defp unsubscribe(%__MODULE__{subscribers: subscribers} = server_state, pid) when is_pid(pid) do
    case Map.pop(subscribers, pid) do
      {nil, _subscribers} ->
        server_state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %__MODULE__{server_state | subscribers: subscribers}
    end
  end

  defp broadcast(
         %__MODULE__{state: %State{agent: %Agent{} = agent}, subscribers: subscribers},
         event
       ) do
    Enum.each(Map.keys(subscribers), fn subscriber ->
      send(subscriber, {:cia, agent, event})
    end)
  end
end
