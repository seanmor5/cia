defmodule CIA.Plan do
  @moduledoc false

  alias CIA.Harness

  @hook_names [:before_start, :after_start, :before_stop, :after_stop]

  defstruct sandbox: nil, workspace: nil, harness: nil, hooks: %{}

  @doc false
  def new do
    %__MODULE__{}
  end

  @doc false
  def put_sandbox(%__MODULE__{} = plan, opts) when is_list(opts) do
    %__MODULE__{plan | sandbox: plan.sandbox |> merge_config(opts) |> ensure_id("sandbox")}
  end

  @doc false
  def put_workspace(%__MODULE__{} = plan, opts) when is_list(opts) do
    %__MODULE__{plan | workspace: plan.workspace |> merge_config(opts) |> ensure_id("workspace")}
  end

  @doc false
  def put_harness(%__MODULE__{} = plan, opts) when is_list(opts) do
    config =
      plan.harness
      |> harness_opts()
      |> Keyword.merge(opts)
      |> ensure_id("agent")

    case Harness.new(config) do
      {:ok, %Harness{} = harness} -> %__MODULE__{plan | harness: harness}
      {:error, reason} -> raise ArgumentError, "invalid harness configuration: #{inspect(reason)}"
    end
  end

  @doc false
  def put_hook(%__MODULE__{} = plan, hook_name, fun) when is_function(fun, 1) do
    case hook_name in @hook_names do
      true ->
        hooks = Map.update(plan.hooks, hook_name, [fun], &(&1 ++ [fun]))
        %__MODULE__{plan | hooks: hooks}

      false ->
        raise ArgumentError, "unsupported hook: #{inspect(hook_name)}"
    end
  end

  defp merge_config(nil, opts), do: Enum.into(opts, %{})
  defp merge_config(config, opts), do: Map.merge(config, Enum.into(opts, %{}))

  defp harness_opts(nil), do: []

  defp harness_opts(%Harness{id: id, harness: harness, config: config}) do
    [id: id, harness: harness] ++ Map.to_list(config)
  end

  defp ensure_id(config, prefix) when is_map(config) do
    Map.put_new_lazy(config, :id, fn ->
      prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    end)
  end

  defp ensure_id(opts, prefix) when is_list(opts) do
    Keyword.put_new_lazy(opts, :id, fn ->
      prefix <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    end)
  end
end
