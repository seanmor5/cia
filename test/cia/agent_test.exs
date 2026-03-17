defmodule CIA.AgentTest do
  use ExUnit.Case, async: true

  alias CIA.Agent

  test "valid_status?/1 accepts known statuses" do
    for status <- [:starting, :running, :stopping, :stopped, :failed] do
      assert Agent.valid_status?(status)
    end
  end

  test "valid_status?/1 rejects unknown statuses" do
    refute Agent.valid_status?(:unknown)
  end

  test "new builds an agent with defaults" do
    assert {:ok, agent} =
             Agent.new(
               id: "agent_1",
               harness: :codex,
               sandbox: :local
             )

    assert agent.id == "agent_1"
    assert agent.harness == :codex
    assert agent.sandbox == :local
    assert agent.status == :starting
    assert agent.pid == nil
    assert agent.provider_ref == nil
    assert agent.metadata == %{}
  end

  test "new accepts explicit optional fields" do
    pid = self()

    assert {:ok, agent} =
             Agent.new(
               id: "agent_1",
               pid: pid,
               status: :running,
               harness: :codex,
               sandbox: :local,
               provider_ref: %{id: "provider_1"},
               metadata: %{source: "test"}
             )

    assert agent.pid == pid
    assert agent.status == :running
    assert agent.provider_ref == %{id: "provider_1"}
    assert agent.metadata == %{source: "test"}
  end

  test "new requires a non-empty id" do
    assert Agent.new(harness: :codex, sandbox: :local) ==
             {:error, {:invalid_id, :expected_non_empty_string}}
  end

  test "new requires a harness" do
    assert Agent.new(id: "agent_1", sandbox: :local) ==
             {:error, {:missing_option, :harness}}
  end

  test "new requires a sandbox" do
    assert Agent.new(id: "agent_1", harness: :codex) ==
             {:error, {:missing_option, :sandbox}}
  end

  test "new rejects invalid status values" do
    assert Agent.new(id: "agent_1", harness: :codex, sandbox: :local, status: :bogus) ==
             {:error, {:invalid_status, :bogus}}
  end

  test "new rejects non-map metadata" do
    assert Agent.new(id: "agent_1", harness: :codex, sandbox: :local, metadata: [:bad]) ==
             {:error, {:invalid_metadata, :expected_map}}
  end
end
