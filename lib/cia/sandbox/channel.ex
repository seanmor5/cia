defmodule CIA.Sandbox.Channel do
  @moduledoc false

  @callback send(pid(), iodata()) :: :ok | {:error, term()}
  @callback stop(pid(), timeout()) :: :ok | {:error, term()}
  @callback set_owner(pid(), pid()) :: :ok | {:error, term()}

  defstruct [:module, :pid, metadata: %{}]

  def new(module, pid, metadata \\ %{})
      when is_atom(module) and is_pid(pid) and is_map(metadata) do
    %__MODULE__{module: module, pid: pid, metadata: metadata}
  end

  def send(%__MODULE__{module: module, pid: pid}, data) do
    module.send(pid, data)
  end

  def stop(%__MODULE__{module: module, pid: pid}, timeout \\ 5_000) do
    module.stop(pid, timeout)
  end

  def set_owner(%__MODULE__{module: module, pid: pid}, owner) when is_pid(owner) do
    module.set_owner(pid, owner)
  end
end
