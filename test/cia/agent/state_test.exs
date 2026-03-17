defmodule CIA.Agent.StateTest do
  use ExUnit.Case, async: true

  alias CIA.Agent.State
  alias CIA.{Harness, Sandbox, Thread, Turn, Workspace}

  test "new builds state from harness sandbox and workspace" do
    before_start = fn _context -> :ok end

    assert {:ok, state} =
             State.new(
               harness: harness(auth: {:api_key, "test-key"}),
               sandbox: sandbox(),
               workspace: workspace(),
               hooks: %{before_start: [before_start]},
               env: %{"CIA_ENV" => "test"},
               metadata: %{source: "test"}
             )

    assert state.agent.id == "agent_1"
    assert state.agent.status == :starting
    assert state.agent.harness == :codex
    assert state.agent.sandbox == :local
    assert state.agent.metadata == %{source: "test"}
    assert state.auth == {:api_key, "test-key"}
    assert state.hooks == %{before_start: [before_start]}
    assert state.env == %{"CIA_ENV" => "test"}
    assert state.threads == %{}
    assert state.turns == %{}
  end

  test "new returns invalid_state when env is not a map" do
    assert State.new(
             harness: harness(),
             sandbox: sandbox(),
             workspace: workspace(),
             env: [:bad]
           ) == {:error, :invalid_state}
  end

  test "new returns invalid_state when hooks are not unary callback lists" do
    assert State.new(
             harness: harness(),
             sandbox: sandbox(),
             workspace: workspace(),
             hooks: %{before_start: [:bad]}
           ) == {:error, :invalid_state}
  end

  test "put_agent_status updates to a valid status" do
    state = state!()

    assert {:ok, updated_state} = State.put_agent_status(state, :running)
    assert updated_state.agent.status == :running
  end

  test "put_agent_status rejects an invalid status" do
    assert {:error, {:invalid_status, :bogus}} =
             state!()
             |> State.put_agent_status(:bogus)
  end

  test "put_harness replaces the stored harness" do
    state = state!()
    updated_harness = harness(id: "agent_2", auth: {:api_key, "other-key"})

    updated_state = State.put_harness(state, updated_harness)

    assert updated_state.harness == updated_harness
  end

  test "put_thread and get_thread store and fetch threads by id" do
    state = state!()

    thread =
      Thread.new(
        id: "thread_1",
        agent_id: "agent_1",
        provider_ref: %{id: "thread_1"},
        status: :active
      )

    updated_state = State.put_thread(state, thread)

    assert {:ok, ^thread} = State.get_thread(updated_state, "thread_1")
  end

  test "get_thread returns a not found error for unknown ids" do
    assert {:error, {:thread_not_found, "missing"}} = State.get_thread(state!(), "missing")
  end

  test "put_turn and get_turn store and fetch turns by id" do
    state = state!()

    turn =
      Turn.new(
        id: "turn_1",
        thread_id: "thread_1",
        provider_ref: %{id: "turn_1"},
        status: :running
      )

    updated_state = State.put_turn(state, turn)

    assert {:ok, ^turn} = State.get_turn(updated_state, "turn_1")
  end

  test "get_turn returns a not found error for unknown ids" do
    assert {:error, {:turn_not_found, "missing"}} = State.get_turn(state!(), "missing")
  end

  test "update_turn_status updates the stored turn and returns it" do
    state =
      state!()
      |> State.put_turn(
        Turn.new(
          id: "turn_1",
          thread_id: "thread_1",
          provider_ref: %{id: "turn_1"},
          status: :running
        )
      )

    assert {:ok, updated_state, updated_turn} =
             State.update_turn_status(state, "turn_1", :cancelled)

    assert updated_turn.status == :cancelled
    assert {:ok, ^updated_turn} = State.get_turn(updated_state, "turn_1")
  end

  test "update_turn_status returns a not found error for unknown ids" do
    assert {:error, {:turn_not_found, "missing"}} =
             State.update_turn_status(state!(), "missing", :cancelled)
  end

  test "put_sandbox replaces the stored sandbox runtime" do
    state = state!()
    updated_sandbox = %{channel: :fake}

    updated_state = State.put_sandbox(state, updated_sandbox)

    assert updated_state.sandbox == updated_sandbox
  end

  test "put_workspace replaces the stored workspace runtime" do
    state = state!()
    updated_workspace = %{root: "/other"}

    updated_state = State.put_workspace(state, updated_workspace)

    assert updated_state.workspace == updated_workspace
  end

  defp state! do
    {:ok, state} =
      State.new(
        harness: harness(),
        sandbox: sandbox(),
        workspace: workspace()
      )

    state
  end

  defp harness(opts \\ []) do
    id = Keyword.get(opts, :id, "agent_1")

    config =
      opts
      |> Keyword.drop([:id])
      |> Keyword.put(:id, id)
      |> Keyword.put_new(:harness, :codex)

    {:ok, harness} = Harness.new(config)
    harness
  end

  defp sandbox do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_1", provider: :local)
    sandbox
  end

  defp workspace do
    {:ok, workspace} =
      Workspace.new(
        sandbox(),
        id: "workspace_1",
        root: "/sandbox",
        kind: :directory
      )

    workspace
  end
end
