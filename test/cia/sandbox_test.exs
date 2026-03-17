defmodule CIA.SandboxTest do
  use ExUnit.Case, async: true

  alias CIA.Sandbox

  defmodule FakeSandbox do
    def start(sandbox, opts), do: {:ok, %{sandbox: sandbox, opts: opts}}
    def stop(sandbox), do: {:ok, sandbox}
    def exec(sandbox, command, opts), do: {:ok, %{sandbox: sandbox, command: command, opts: opts}}
  end

  defmodule SandboxWithoutExec do
    def start(_sandbox, _opts), do: {:ok, :started}
    def stop(_sandbox), do: :ok
  end

  test "new builds a sandbox and stores config separately from metadata" do
    assert {:ok, sandbox} =
             Sandbox.new(
               id: "sandbox_1",
               provider: :local,
               mode: :workspace_write,
               metadata: %{source: "test"}
             )

    assert sandbox.id == "sandbox_1"
    assert sandbox.provider == :local
    assert sandbox.config == %{mode: :workspace_write}
    assert sandbox.metadata == %{source: "test"}
  end

  test "new requires a provider" do
    assert Sandbox.new(id: "sandbox_1") == {:error, {:missing_option, :provider}}
  end

  test "new rejects non-map metadata" do
    assert Sandbox.new(id: "sandbox_1", provider: :local, metadata: [:bad]) ==
             {:error, {:invalid_metadata, :expected_map}}
  end

  test "module_for resolves built-in and custom providers" do
    assert Sandbox.module_for(:local) == {:ok, CIA.Sandbox.Local}
    assert Sandbox.module_for(:sprite) == {:ok, CIA.Sandbox.Sprite}
    assert Sandbox.module_for(FakeSandbox) == {:ok, FakeSandbox}
  end

  test "module_for rejects invalid providers" do
    assert Sandbox.module_for("local") == {:error, {:invalid_sandbox, "local"}}
  end

  test "start delegates to the sandbox module" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.start(sandbox, command: {"echo", ["ok"]}) ==
             {:ok, %{sandbox: sandbox, opts: [command: {"echo", ["ok"]}]}}
  end

  test "local start returns command_not_found for missing executables" do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_2", provider: :local)

    assert Sandbox.start(sandbox, command: ["cia-command-that-does-not-exist"]) ==
             {:error, {:command_not_found, "cia-command-that-does-not-exist"}}
  end

  test "exec delegates to the sandbox module when supported" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.exec(sandbox, ["echo", "ok"], cwd: "/tmp") ==
             {:ok, %{sandbox: sandbox, command: ["echo", "ok"], opts: [cwd: "/tmp"]}}
  end

  test "local exec returns command_not_found for missing executables" do
    sandbox = %CIA.Sandbox.Local{}

    assert Sandbox.exec(sandbox, ["cia-command-that-does-not-exist"]) ==
             {:error, {:command_not_found, "cia-command-that-does-not-exist"}}
  end

  test "exec returns an unsupported operation error when exec is not exported" do
    sandbox = %Sandbox{id: "sandbox_1", provider: SandboxWithoutExec}

    assert Sandbox.exec(sandbox, ["echo", "ok"]) ==
             {:error, {:unsupported_sandbox_operation, :exec}}
  end

  test "stop delegates to the sandbox module" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.stop(sandbox) == {:ok, sandbox}
  end
end
