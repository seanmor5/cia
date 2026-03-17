defmodule CIA.Thread do
  @moduledoc false

  @enforce_keys [:id, :agent_id, :provider_ref, :status]
  defstruct [:id, :agent_id, :provider_ref, :status, metadata: %{}]

  @doc false
  def new(opts) when is_list(opts) do
    %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      agent_id: Keyword.fetch!(opts, :agent_id),
      provider_ref: Keyword.fetch!(opts, :provider_ref),
      status: Keyword.get(opts, :status, :active),
      metadata: Keyword.get(opts, :metadata, %{}) || %{}
    }
  end
end
