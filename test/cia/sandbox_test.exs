defmodule CIA.SandboxTest do
  use ExUnit.Case, async: true

  alias CIA.Sandbox

  defmodule FakeSandbox do
    def start(sandbox, opts), do: {:ok, %{sandbox: sandbox, opts: opts}}
    def stop(sandbox), do: {:ok, sandbox}

    def exec(sandbox, command, opts),
      do:
        {:ok,
         %{
           sandbox: sandbox,
           command: command,
           opts: opts,
           stdout: "ok\n",
           stderr: "",
           exit_code: 0
         }}
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
    assert sandbox.config == %{lifecycle: :ephemeral, mode: :workspace_write}
    assert sandbox.metadata == %{source: "test"}
  end

  test "new defaults Sprite lifecycle to ephemeral" do
    assert {:ok, sandbox} =
             Sandbox.new(
               id: "sandbox_1",
               provider: :sprite,
               token: "sprite-token"
             )

    assert sandbox.config == %{lifecycle: :ephemeral, token: "sprite-token"}
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

  test "new rejects unsupported local sandbox lifecycles" do
    assert Sandbox.new(id: "sandbox_1", provider: :local, lifecycle: :durable) ==
             {:error, {:unsupported_sandbox_lifecycle, :local, :durable}}
  end

  test "new rejects invalid lifecycle values" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :bogus,
             token: "sprite-token"
           ) ==
             {:error, {:invalid_option, {:lifecycle, :bogus}}}
  end

  test "new requires a name for durable Sprite sandboxes" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :durable,
             token: "sprite-token"
           ) ==
             {:error, {:missing_option, :name}}
  end

  test "new requires a name for attached Sprite sandboxes" do
    assert Sandbox.new(
             id: "sandbox_1",
             provider: :sprite,
             lifecycle: :attached,
             token: "sprite-token"
           ) ==
             {:error, {:missing_option, :name}}
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

  test "local start carries the normalized lifecycle into the runtime" do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_2", provider: :local)

    assert {:ok, runtime} = Sandbox.start(sandbox, command: ["/bin/sh", "-lc", "sleep 1"])
    assert runtime.lifecycle == :ephemeral

    assert :ok = Sandbox.stop(runtime)
  end

  test "cmd delegates to the sandbox module and returns System.cmd-style output" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.cmd(sandbox, "echo", ["ok"], cd: "/tmp") == {"ok\n", 0}
  end

  test "cmd returns sandbox errors when the executable is missing" do
    sandbox = %CIA.Sandbox.Local{}

    assert Sandbox.cmd(sandbox, "cia-command-that-does-not-exist") ==
             {:error, {:command_not_found, "cia-command-that-does-not-exist"}}
  end

  test "cmd returns output and status for non-zero exits" do
    sandbox = %CIA.Sandbox.Local{}

    assert Sandbox.cmd(sandbox, "/bin/sh", ["-lc", "printf failing && exit 7"]) ==
             {"failing", 7}
  end

  test "cmd returns an unsupported operation error when exec is not exported" do
    sandbox = %Sandbox{id: "sandbox_1", provider: SandboxWithoutExec}

    assert Sandbox.cmd(sandbox, "echo", ["ok"]) ==
             {:error, {:unsupported_sandbox_operation, :cmd}}
  end

  test "cmd respects the into option" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.cmd(sandbox, "echo", ["ok"], into: []) == {["ok\n"], 0}
  end

  test "stop delegates to the sandbox module" do
    sandbox = %Sandbox{id: "sandbox_1", provider: FakeSandbox}

    assert Sandbox.stop(sandbox) == {:ok, sandbox}
  end
end
