defmodule CIA.Workspace.Directory do
  @moduledoc false

  @behaviour CIA.Workspace

  alias CIA.Workspace

  def materialize(%Workspace{} = workspace, _sandbox) do
    {:ok, workspace}
  end

  def cleanup(%Workspace{} = _workspace, _sandbox) do
    :ok
  end
end
