defmodule CIA.Sandbox.SpriteLiveTest do
  use ExUnit.Case, async: false

  alias CIA.Sandbox
  alias CIA.Sandbox.Channel

  @moduletag :sprite_live

  setup_all do
    case sprite_config() do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:skip, reason}
    end
  end

  test "exec runs a real command in Sprite", config do
    sandbox = start_sprite!(config, ["/bin/sh", "-lc", "sleep 30"])

    assert {:ok, output} =
             Sandbox.exec(
               sandbox,
               ["/bin/sh", "-lc", "printf %s \"$CIA_SPRITE_TEST_VALUE\""],
               env: %{"CIA_SPRITE_TEST_VALUE" => "sprite-ok"}
             )

    assert output.stdout == "sprite-ok"
    assert output.stderr == ""
    assert output.exit_code == 0
  end

  test "interactive exec streams stdout over the Sprite channel", config do
    sandbox = start_sprite!(config, ["cat"])
    marker = "sprite-roundtrip-#{System.unique_integer([:positive])}\n"

    assert_receive {:cia_sandbox_channel, channel_pid, {:message, %{"type" => "session_info"}}},
                   15_000

    assert channel_pid == sandbox.channel.pid
    assert :ok = Channel.send(sandbox.channel, marker)
    assert_receive_data(channel_pid, marker, "")
  end

  defp start_sprite!(config, command) do
    sandbox_config =
      [
        id: "sprite_live_#{System.unique_integer([:positive])}",
        provider: :sprite,
        name: config.name,
        token: config.token
      ]
      |> maybe_put_base_url(config.base_url)

    {:ok, sandbox} = Sandbox.new(sandbox_config)
    {:ok, runtime} = Sandbox.start(sandbox, command: command)

    ExUnit.Callbacks.on_exit(fn ->
      Sandbox.stop(runtime)
    end)

    runtime
  end

  defp sprite_config do
    name = System.get_env("CIA_SPRITE_NAME")
    token = System.get_env("CIA_SPRITE_TOKEN")
    base_url = System.get_env("CIA_SPRITE_BASE_URL")

    cond do
      blank?(name) ->
        {:error, "set CIA_SPRITE_NAME to run Sprite live tests"}

      blank?(token) ->
        {:error, "set CIA_SPRITE_TOKEN to run Sprite live tests"}

      true ->
        {:ok, %{name: name, token: token, base_url: normalize_blank(base_url)}}
    end
  end

  defp assert_receive_data(channel_pid, expected, acc) do
    receive do
      {:cia_sandbox_channel, ^channel_pid, {:data, chunk}} ->
        new_acc = acc <> chunk

        if String.contains?(new_acc, expected) do
          assert new_acc =~ expected
        else
          assert_receive_data(channel_pid, expected, new_acc)
        end

      {:cia_sandbox_channel, ^channel_pid, {:stderr, chunk}} ->
        flunk("unexpected stderr from Sprite channel: #{inspect(chunk)}")

      {:cia_sandbox_channel, ^channel_pid, {:exit, reason}} ->
        flunk("Sprite channel exited before echoing stdin: #{inspect(reason)}")
    after
      15_000 ->
        flunk("timed out waiting for Sprite channel data containing #{inspect(expected)}")
    end
  end

  defp maybe_put_base_url(opts, nil), do: opts
  defp maybe_put_base_url(opts, base_url), do: Keyword.put(opts, :base_url, base_url)

  defp blank?(value), do: value in [nil, ""]
  defp normalize_blank(value) when value in [nil, ""], do: nil
  defp normalize_blank(value), do: value
end
