defmodule CIA do
  @moduledoc """
  The CIA (Central Intelligence Agent) is an opinionated library for managing
  background agents from Elixir apps.

  ## Overview

  CIA manages 3 abstractions internally:

    1. The sandbox, e.g. where code can run
    2. The workspace, e.g. what filesystem scope work should happen in
    3. The harness, e.g. what agent you're running

  And is concerned with 3 core models:

    1. Agents - A single instance of a running background agent
    2. Threads - A chain of requests belonging to a single agent
    3. Turns - A single request/response within a single thread

  Each background agent runs as a GenServer. CIA can start agents directly or
  under a caller-provided supervisor. Agent state is all persisted in-memory
  and does not survive across application restarts.

  ## Creating Agents

  CIA agents are configured through a pipeable builder:

      config =
        CIA.new()
        |> CIA.sandbox(:local)
        |> CIA.workspace(:directory, root: "/workspace")
        |> CIA.before_start(fn %{sandbox: sandbox} ->
          {:ok, _} = CIA.exec(sandbox, ["mkdir", "-p", "/workspace/lib"]),
          {:ok, _} = CIA.exec(sandbox, ["git", "clone", "repo"]
          :ok
        end)
        |> CIA.harness(:codex, auth: {:api_key, System.fetch_env!("OPENAI_API_KEY")})

      {:ok, agent} = CIA.start(config)

  CIA also supports agent-scoped lifecycle hooks like `before_start/2` and
  `after_stop/2`. These hooks are named relative to the agent operation, not
  the sandbox. `before_start/2` runs after the sandbox exists but before the
  agent harness session starts, which makes it the right place to create
  directories, sync files, write seed config, and verify prerequisites before
  Codex begins handling requests.

  Authentication is configured on the harness builder step and is treated as a
  harness-level concern. CIA currently supports:

  - `auth: {:api_key, key}`

  CIA stores that auth privately and passes it to the active harness during
  session startup. It is not exposed on public handles and is not configured per
  thread or per turn.

  ## Running Background Agents

  `start/1` starts an agent server process and returns a `%CIA.Agent{}` struct.
  All public operations require this handle.

  After starting an agent, you can create and interact with threads:

      {:ok, thread} = CIA.thread(agent,
        cwd: "/workspace",
        model: "gpt-5.4"
      )

      {:ok, turn} = CIA.turn(agent, thread, "Implement a Linked List in C")
      CIA.steer(agent, turn, "And please add tests")
      CIA.cancel(agent, turn)

  Once you are done with an agent, you can stop it with `CIA.stop(agent)`.

  ## Events

  CIA supports agent-level subscriptions through `subscribe/2`.

  Subscribers currently receive messages in this form:

      {:cia, %CIA.Agent{}, event}

  In the current implementation, `event` is a forwarded harness event:

      {:harness, harness_name, payload}

  This is intentionally narrow for now. CIA does not yet normalize all harness
  notifications into higher-level thread and turn lifecycle events.
  """

  alias CIA.{Agent, Plan, Sandbox, Thread, Workspace}
  alias CIA.Agent.Server

  @hook_names [:before_start, :after_start, :before_stop, :after_stop]

  @doc """
  Creates a new pipeable CIA configuration.

  Configurations are pure builders. They do not provision a sandbox,
  create a workspace, or start an agent on their own.
  """
  def new do
    Plan.new()
  end

  @doc """
  Adds sandbox configuration to a pipeable CIA configuration.

  The first argument selects the sandbox provider. All remaining
  sandbox configuration belongs here, including provider-specific
  options and identifiers.
  """
  def sandbox(%Plan{} = plan, provider, opts \\ [])
      when is_atom(provider) and is_list(opts) do
    Plan.put_sandbox(plan, Keyword.put(opts, :provider, provider))
  end

  @doc """
  Adds workspace configuration to a pipeable CIA configuration.

  The first argument selects the workspace kind. All remaining
  workspace configuration belongs here, including root paths,
  names, and identifiers.
  """
  def workspace(%Plan{} = plan, kind, opts \\ [])
      when is_atom(kind) and is_list(opts) do
    Plan.put_workspace(plan, Keyword.put(opts, :kind, kind))
  end

  @doc """
  Adds an agent lifecycle hook to a pipeable CIA configuration.

  Supported hook names are:

  - `:before_start`
  - `:after_start`
  - `:before_stop`
  - `:after_stop`

  Hook callbacks are unary functions that receive a context map. `before_*`
  hooks must return `:ok`; any other return value aborts that agent operation.
  `after_*` hooks are observational and receive the final `:result` for the
  attempted operation.

  These hooks are agent-scoped. `before_start/2` and `after_start/2` are
  relative to the CIA agent lifecycle, not sandbox lifecycle. `before_start/2`
  receives the live sandbox runtime because sandbox provisioning happens before
  the agent is considered started.
  """
  def hook(%Plan{} = plan, hook_name, fun) when is_atom(hook_name) and is_function(fun, 1) do
    Plan.put_hook(plan, hook_name, fun)
  end

  for hook_name <- @hook_names do
    @doc "Adds a `#{hook_name}` agent lifecycle hook to a pipeable CIA configuration."
    def unquote(hook_name)(%Plan{} = plan, fun) when is_function(fun, 1) do
      hook(plan, unquote(hook_name), fun)
    end
  end

  @doc """
  Adds harness configuration to a pipeable CIA configuration.

  The first argument selects the harness implementation. This configuration is
  stored on the returned builder state and does not start a live agent on its
  own. All remaining harness configuration belongs here,
  including harness, auth, names, and identifiers.
  """
  def harness(%Plan{} = plan, harness, opts \\ [])
      when is_atom(harness) and is_list(opts) do
    Plan.put_harness(plan, Keyword.put(opts, :harness, harness))
  end

  @doc """
  Starts a managed agent process.

  The returned handle is a `%CIA.Agent{}`. `start/1` consumes configuration
  built with the pipeable `sandbox/3`, `workspace/3`, and `harness/3` helpers.
  Configuration belongs on that builder. `start/1` executes it.

  By default, the agent process is started directly. To start it under your own
  supervisor, pass `supervisor: MyApp.CIAAgentSupervisor`.
  """
  def start(%Plan{} = plan, opts \\ []) when is_list(opts) do
    with {:ok, start_opts} <- plan_start_opts(plan),
         {:ok, pid} <- start_agent(start_opts, Keyword.get(opts, :supervisor)) do
      {:ok, Server.agent(pid)}
    end
  end

  @doc """
  Executes a one-shot command on a live sandbox runtime.

  This is primarily intended for use from `before_start/2` hooks.
  """
  def exec(sandbox, command, opts \\ []) when is_list(command) and is_list(opts) do
    Sandbox.exec(sandbox, command, opts)
  end

  defp start_agent(opts, nil), do: Server.start_link(opts)

  defp start_agent(opts, supervisor),
    do: DynamicSupervisor.start_child(supervisor, {Server, opts})

  defp plan_start_opts(%Plan{} = plan) do
    with :ok <- validate_harness_config(plan.harness),
         {:ok, sandbox} <- plan_sandbox(plan),
         {:ok, workspace} <- plan_workspace(plan, sandbox) do
      {:ok,
       [
         harness: plan.harness,
         sandbox: sandbox,
         workspace: workspace,
         hooks: plan.hooks
       ]}
    end
  end

  @doc """
  Stops a managed agent process.

  Stopping an already-exited or unknown agent is treated as a successful no-op.

  Stopping an agent tears down the harness session and then asks the sandbox to
  clean up its runtime resources.
  """
  def stop(%Agent{pid: pid}, timeout \\ :infinity) do
    case pid do
      nil -> :ok
      pid -> Server.stop(pid, timeout)
    end
  end

  @doc """
  Subscribes a process to agent events.

  If no subscriber PID is provided, the calling process is subscribed.

  Subscribers receive messages in the form:

      {:cia, %CIA.Agent{}, event}

  The current event stream forwards harness-originated events from the running
  agent process:

      {:cia, agent, {:harness, :codex, payload}}

  Subscriptions are agent-wide. You cannot scope to specific events at this time.

  Subscribers are monitored and automatically removed when the subscriber
  process exits.
  """
  def subscribe(%Agent{pid: pid}, subscriber \\ self()) when is_pid(pid) and is_pid(subscriber) do
    Server.subscribe(pid, subscriber)
  end

  @doc """
  Creates a new thread on an agent.

  When creating a new thread with keyword options, the current supported keys
  are:

  - `:cwd`
  - `:model`
  - `:system_prompt`
  - `:metadata`

  `:metadata` is stored by CIA on the returned `%CIA.Thread{}`. The remaining
  options are currently forwarded to the active harness. For the current Codex
  harness, they map to thread creation settings for the underlying app-server
  request.
  """
  def thread(%Agent{pid: pid}, opts) when is_pid(pid) and is_list(opts) do
    Server.start_thread(pid, opts)
  end

  @doc """
  Submits a turn to a thread.

  The thread must be provided as a `%CIA.Thread{}` handle returned by CIA.

  The returned `%CIA.Turn{}` reflects CIA's local runtime view. In the current
  implementation, turns are marked `:running` when submitted and may later emit
  additional harness events through `subscribe/2`.
  """
  def turn(%Agent{pid: pid}, %Thread{} = thread, input, opts \\ [])
      when is_pid(pid) and is_list(opts) do
    Server.submit_turn(pid, thread, input, opts)
  end

  @doc """
  Sends additional input to a running turn.

  `turn_or_id` may be a `%CIA.Turn{}` or a known turn identifier.

  This is intended for live turn steering while the turn is still running.
  """
  def steer(%Agent{pid: pid}, turn_or_id, input, opts \\ []) when is_pid(pid) and is_list(opts) do
    Server.steer_turn(pid, turn_or_id, input, opts)
  end

  @doc """
  Cancels a running turn.

  `turn_or_id` may be a `%CIA.Turn{}` or a known turn identifier.

  On success, CIA updates its in-memory turn status to `:cancelled` and moves
  the owning thread back to `:active`.
  """
  def cancel(%Agent{pid: pid}, turn_or_id) when is_pid(pid) do
    Server.cancel_turn(pid, turn_or_id)
  end

  defp plan_sandbox(%Plan{sandbox: nil}), do: {:error, {:missing_option, :sandbox}}

  defp plan_sandbox(%Plan{sandbox: sandbox_config}) when is_map(sandbox_config) do
    sandbox_config
    |> Map.to_list()
    |> Sandbox.new()
  end

  defp plan_workspace(%Plan{workspace: nil}, _sandbox),
    do: {:error, {:missing_option, :workspace}}

  defp plan_workspace(%Plan{workspace: workspace_config}, %Sandbox{} = sandbox)
       when is_map(workspace_config) do
    workspace_config
    |> Map.to_list()
    |> then(&Workspace.new(sandbox, &1))
  end

  defp validate_harness_config(nil), do: :ok

  defp validate_harness_config(%CIA.Harness{config: config}) do
    if Map.has_key?(config, :cwd) or Map.has_key?(config, "cwd") do
      {:error, {:invalid_option, {:harness, :cwd}}}
    else
      :ok
    end
  end
end
