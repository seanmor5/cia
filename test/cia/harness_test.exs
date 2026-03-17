defmodule CIA.HarnessTest do
  use ExUnit.Case, async: true

  alias CIA.Harness

  defmodule FakeHarness do
    def runtime_command(_state), do: {"fake-harness", ["serve"]}
    def start_session(state), do: {:ok, {:session, state}, []}
    def stop_session(session), do: {:ok, session}
    def start_thread(session, opts), do: {:ok, %{session: session, opts: opts}}

    def submit_turn(session, thread_ref, input, opts),
      do: {:ok, %{session: session, thread_ref: thread_ref, input: input, opts: opts}}

    def steer_turn(session, turn_ref, input, opts),
      do: {:ok, %{session: session, turn_ref: turn_ref, input: input, opts: opts}}

    def cancel_turn(session, turn_ref), do: {:ok, %{session: session, turn_ref: turn_ref}}
  end

  defmodule InvalidRuntimeCommandHarness do
    def runtime_command(_state), do: :invalid
  end

  test "new builds a harness and stores config separately" do
    assert {:ok, harness} =
             Harness.new(
               id: "agent_1",
               harness: :codex,
               auth: {:api_key, "test-key"},
               command: {"codex", ["app-server"]}
             )

    assert harness.id == "agent_1"
    assert harness.harness == :codex
    assert harness.config[:auth] == {:api_key, "test-key"}
    assert harness.config[:command] == {"codex", ["app-server"]}
  end

  test "new requires a harness implementation" do
    assert Harness.new(id: "agent_1") == {:error, {:missing_option, :harness}}
  end

  test "module_for resolves built-in and custom harnesses" do
    assert Harness.module_for(:codex) == {:ok, CIA.Harness.Codex}
    assert Harness.module_for(FakeHarness) == {:ok, FakeHarness}
  end

  test "module_for rejects invalid harnesses" do
    assert Harness.module_for("codex") == {:error, {:invalid_harness, "codex"}}
  end

  test "runtime_command delegates and validates the returned shape" do
    assert Harness.runtime_command(%{harness: FakeHarness}) == {:ok, {"fake-harness", ["serve"]}}

    assert Harness.runtime_command(%{harness: InvalidRuntimeCommandHarness}) ==
             {:error, {:invalid_runtime_command, :invalid}}
  end

  test "start_session delegates to the harness module" do
    state = %{harness: FakeHarness, session: %{pid: self()}}

    assert Harness.start_session(state) == {:ok, {:session, state}, []}
  end

  test "stop_session delegates to the harness module" do
    session = %{harness: FakeHarness, session: %{pid: self()}}

    assert Harness.stop_session(session) == {:ok, session}
  end

  test "start_thread delegates to the harness module" do
    session = %{harness: FakeHarness}

    assert Harness.start_thread(session, cwd: "/sandbox") ==
             {:ok, %{session: session, opts: [cwd: "/sandbox"]}}
  end

  test "submit_turn delegates to the harness module" do
    session = %{harness: FakeHarness}
    thread_ref = %{id: "thread_1"}

    assert Harness.submit_turn(session, thread_ref, "Build it", model: "gpt-5.4") ==
             {:ok,
              %{
                session: session,
                thread_ref: thread_ref,
                input: "Build it",
                opts: [model: "gpt-5.4"]
              }}
  end

  test "steer_turn delegates to the harness module" do
    session = %{harness: FakeHarness}
    turn_ref = %{id: "turn_1"}

    assert Harness.steer_turn(session, turn_ref, "Add tests", timeout: 1_000) ==
             {:ok,
              %{
                session: session,
                turn_ref: turn_ref,
                input: "Add tests",
                opts: [timeout: 1_000]
              }}
  end

  test "cancel_turn delegates to the harness module" do
    session = %{harness: FakeHarness}
    turn_ref = %{id: "turn_1"}

    assert Harness.cancel_turn(session, turn_ref) ==
             {:ok, %{session: session, turn_ref: turn_ref}}
  end
end
