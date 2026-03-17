defmodule CIA.WorkspaceTest do
  use ExUnit.Case, async: true

  alias CIA.{Sandbox, Workspace}

  test "new builds a directory workspace" do
    sandbox = sandbox()

    assert {:ok, workspace} =
             Workspace.new(
               sandbox,
               id: "workspace_1",
               root: "/sandbox",
               kind: :directory,
               mode: :shared,
               metadata: %{team: "cia"}
             )

    assert workspace.id == "workspace_1"
    assert workspace.sandbox == sandbox
    assert workspace.root == "/sandbox"
    assert workspace.kind == :directory
    assert workspace.config == %{mode: :shared}
    assert workspace.metadata == %{team: "cia"}
  end

  test "new requires a root" do
    assert Workspace.new(sandbox(), id: "workspace_1") == {:error, {:missing_option, :root}}
  end

  test "new rejects unsupported workspace kinds" do
    assert Workspace.new(sandbox(), id: "workspace_1", root: "/sandbox", kind: :volume) ==
             {:error, {:unsupported_workspace_kind, :volume}}
  end

  test "module_for resolves the built-in directory workspace" do
    assert Workspace.module_for(workspace()) == {:ok, CIA.Workspace.Directory}
  end

  test "module_for rejects unsupported workspace kinds" do
    unsupported_workspace = %Workspace{
      id: "workspace_1",
      sandbox: sandbox(),
      root: "/sandbox",
      kind: :volume
    }

    assert Workspace.module_for(unsupported_workspace) ==
             {:error, {:unsupported_workspace_kind, :volume}}
  end

  test "materialize delegates to the directory workspace module" do
    workspace = workspace()

    assert Workspace.materialize(workspace, :sandbox_runtime) == {:ok, workspace}
  end

  test "cleanup delegates to the directory workspace module" do
    assert Workspace.cleanup(workspace(), :sandbox_runtime) == :ok
  end

  defp sandbox do
    {:ok, sandbox} = Sandbox.new(id: "sandbox_1", provider: :local)
    sandbox
  end

  defp workspace do
    {:ok, workspace} =
      Workspace.new(sandbox(), id: "workspace_1", root: "/sandbox", kind: :directory)

    workspace
  end
end
