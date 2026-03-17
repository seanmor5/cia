defmodule CIA.TestSupport.FakeCodexServer do
  @moduledoc false

  @runner_path Path.expand("fake_codex_server.py", __DIR__)

  def command(opts \\ []) when is_list(opts) do
    scenario = Keyword.get(opts, :scenario, %{})
    trace_file = Keyword.get(opts, :trace_file)

    args =
      [
        @runner_path,
        "--scenario",
        Jason.encode!(deep_merge(default_scenario(), stringify(scenario)))
      ]
      |> maybe_put_trace_file_arg(trace_file)

    {"python3", args}
  end

  def trace_file(name \\ "fake-codex-server") when is_binary(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.jsonl")
  end

  def read_trace!(path) when is_binary(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  def default_scenario do
    %{
      "account" => %{"id" => "acct_test", "email" => "fake@example.com"},
      "requires_openai_auth" => false,
      "login_response" => %{"type" => "apiKey"},
      "thread_ids" => ["thread_test"],
      "turn_ids" => ["turn_test"],
      "errors" => %{},
      "events" => %{},
      "exit_after" => []
    }
  end

  defp maybe_put_trace_file_arg(args, nil), do: args
  defp maybe_put_trace_file_arg(args, path), do: args ++ ["--trace-file", path]

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp stringify(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) -> {Atom.to_string(key), stringify(nested)}
      {key, nested} -> {key, stringify(nested)}
    end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
