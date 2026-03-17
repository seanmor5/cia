defmodule CIA.Turn do
  @moduledoc false

  @enforce_keys [:id, :thread_id, :status, :provider_ref]
  defstruct [:id, :thread_id, :status, :provider_ref, metadata: %{}]

  @doc false
  def new(opts) when is_list(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      thread_id: Keyword.fetch!(opts, :thread_id),
      provider_ref: Keyword.fetch!(opts, :provider_ref),
      status: Keyword.get(opts, :status, :running),
      metadata: Keyword.get(opts, :metadata, %{}) || %{}
    }
  end
end
