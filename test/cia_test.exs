defmodule CIATest do
  use ExUnit.Case, async: false

  alias CIA.Plan
  alias CIA.TestSupport.FakeCodexServer

  setup do
    trace_file = FakeCodexServer.trace_file("cia-fake-codex")

    on_exit(fn ->
      File.rm(trace_file)
    end)

    %{trace_file: trace_file}
  end

  test "new returns an empty plan" do
    assert %Plan{} = plan = CIA.new()

    assert plan.sandbox == nil
    assert plan.workspace == nil
    assert plan.harness == nil
    assert plan.hooks == %{}
  end

  test "sandbox stores the positional provider and preserves the generated id" do
    plan = CIA.new() |> CIA.sandbox(:local, metadata: %{source: "test"})
    sandbox_id = plan.sandbox.id

    updated_plan = CIA.sandbox(plan, :local, mode: :workspace_write)

    assert updated_plan.sandbox.id == sandbox_id
    assert updated_plan.sandbox.provider == :local
    assert updated_plan.sandbox.metadata == %{source: "test"}
    assert updated_plan.sandbox.mode == :workspace_write
  end

  test "workspace stores the positional kind and root" do
    plan = CIA.new() |> CIA.workspace(:directory, root: "/sandbox", metadata: %{team: "cia"})

    assert plan.workspace.kind == :directory
    assert plan.workspace.root == "/sandbox"
    assert plan.workspace.metadata == %{team: "cia"}
    assert String.starts_with?(plan.workspace.id, "workspace_")
  end

  test "harness stores the positional implementation and config" do
    command = {"python3", ["/tmp/fake_codex.py"]}

    plan =
      CIA.new()
      |> CIA.harness(:codex, auth: {:api_key, "test-key"}, command: command)

    assert plan.harness.harness == :codex
    assert plan.harness.config[:auth] == {:api_key, "test-key"}
    assert plan.harness.config[:command] == command
    assert String.starts_with?(plan.harness.id, "agent_")
  end

  test "hook stores lifecycle callbacks on the plan" do
    before_start = fn _context -> :ok end
    after_start = fn _context -> :ok end

    plan =
      CIA.new()
      |> CIA.before_start(before_start)
      |> CIA.hook(:after_start, after_start)

    assert plan.hooks.before_start == [before_start]
    assert plan.hooks.after_start == [after_start]
  end

  test "start rejects cwd on harness config" do
    plan =
      CIA.new()
      |> CIA.harness(:codex, cwd: "/sandbox")

    assert CIA.start(plan) == {:error, {:invalid_option, {:harness, :cwd}}}
  end

  test "starts an agent against the fake stdio app-server", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)

    assert agent.status == :running
    assert is_pid(agent.pid)
  end

  test "runs start hooks relative to the agent lifecycle", %{trace_file: trace_file} do
    parent = self()

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        plan
        |> CIA.before_start(fn %{agent: agent, sandbox: sandbox} ->
          send(parent, {:before_start, agent.status, sandbox.__struct__})
          :ok
        end)
        |> CIA.after_start(fn %{agent: agent, sandbox: sandbox, result: {:ok, started_agent}} ->
          send(parent, {:after_start, agent.status, sandbox.__struct__, started_agent.status})
          :ok
        end)
      end)

    assert agent.status == :running
    assert_receive {:before_start, :starting, CIA.Sandbox.Local}
    assert_receive {:after_start, :running, CIA.Sandbox.Local, :running}
  end

  test "runs stop hooks around agent shutdown", %{trace_file: trace_file} do
    parent = self()

    {:ok, agent} =
      start_agent(trace_file, %{}, fn plan ->
        plan
        |> CIA.before_stop(fn %{agent: agent, sandbox: sandbox, reason: reason} ->
          send(parent, {:before_stop, agent.status, sandbox.__struct__, reason})
          :ok
        end)
        |> CIA.after_stop(fn %{agent: agent, sandbox: sandbox, reason: reason, result: result} ->
          send(parent, {:after_stop, agent.status, sandbox.__struct__, reason, result})
          :ok
        end)
      end)

    assert :ok = CIA.stop(agent)
    refute Process.alive?(agent.pid)
    assert_receive {:before_stop, :running, CIA.Sandbox.Local, :normal}
    assert_receive {:after_stop, :running, CIA.Sandbox.Local, :normal, :ok}
  end

  test "creates a thread and forwards thread options", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)

    {:ok, thread} =
      CIA.thread(agent,
        cwd: "/sandbox",
        model: "gpt-5.4",
        system_prompt: "Be exact",
        metadata: %{source: "integration"}
      )

    assert thread.id == "thread_test"
    assert thread.status == :active
    assert thread.metadata == %{source: "integration"}

    assert request_payload(trace_file, "thread/start")["params"] == %{
             "baseInstructions" => "Be exact",
             "cwd" => "/sandbox",
             "model" => "gpt-5.4"
           }
  end

  test "starts a turn and records fake server notifications", %{trace_file: trace_file} do
    scenario = %{
      events: %{
        "turn/start" => [
          %{
            method: "turn/updated",
            params: %{"turnId" => "turn_test", "status" => "running"}
          }
        ]
      }
    }

    {:ok, agent} = start_agent(trace_file, scenario)
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")

    {:ok, turn} =
      CIA.turn(agent, thread, "Build it",
        reasoning_effort: "medium",
        metadata: %{kind: "build"}
      )

    assert turn.id == "turn_test"
    assert turn.status == :running
    assert turn.metadata == %{kind: "build"}

    assert request_payload(trace_file, "turn/start")["params"] == %{
             "approvalPolicy" => "never",
             "cwd" => "/sandbox",
             "effort" => "medium",
             "input" => [%{"text" => "Build it", "type" => "text"}],
             "sandboxPolicy" => %{
               "type" => "workspaceWrite",
               "writableRoots" => ["/sandbox"],
               "networkAccess" => false,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             },
             "threadId" => "thread_test"
           }

    assert notification_payload(trace_file, "turn/updated")["params"] == %{
             "turnId" => "turn_test",
             "status" => "running"
           }
  end

  test "steers and cancels a running turn", %{trace_file: trace_file} do
    {:ok, agent} = start_agent(trace_file)
    {:ok, thread} = CIA.thread(agent, cwd: "/sandbox")
    {:ok, turn} = CIA.turn(agent, thread, "Build it")

    assert :ok = CIA.steer(agent, turn, "Add tests")

    assert {:ok, cancelled_turn} = CIA.cancel(agent, turn)
    assert cancelled_turn.status == :cancelled

    assert request_payload(trace_file, "turn/steer")["params"] == %{
             "expectedTurnId" => "turn_test",
             "input" => [%{"text" => "Add tests", "type" => "text"}],
             "threadId" => "thread_test"
           }

    assert request_payload(trace_file, "turn/interrupt")["params"] == %{
             "threadId" => "thread_test",
             "turnId" => "turn_test"
           }
  end

  defp start_agent(trace_file, scenario \\ %{}, plan_fun \\ & &1) do
    config =
      CIA.new()
      |> CIA.sandbox(:local)
      |> CIA.workspace(:directory, root: "/sandbox")
      |> CIA.harness(
        :codex,
        command: FakeCodexServer.command(trace_file: trace_file, scenario: scenario)
      )
      |> plan_fun.()

    result = CIA.start(config)

    case result do
      {:ok, agent} ->
        on_exit(fn ->
          if Process.alive?(agent.pid) do
            CIA.stop(agent)
          end
        end)

      _ ->
        :ok
    end

    result
  end

  defp request_payload(trace_file, method) do
    trace_file
    |> FakeCodexServer.read_trace!()
    |> Enum.find(fn entry ->
      entry["direction"] == "received" and get_in(entry, ["payload", "method"]) == method
    end)
    |> then(fn entry -> entry["payload"] end)
  end

  defp notification_payload(trace_file, method) do
    trace_file
    |> FakeCodexServer.read_trace!()
    |> Enum.find(fn entry ->
      entry["direction"] == "sent" and get_in(entry, ["payload", "method"]) == method
    end)
    |> then(fn entry -> entry["payload"] end)
  end
end
