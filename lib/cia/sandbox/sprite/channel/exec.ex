defmodule CIA.Sandbox.Sprite.Channel.Exec do
  @moduledoc false

  @behaviour CIA.Sandbox.Channel

  use WebSockex

  @default_base_url "https://api.sprites.dev"

  def start_link(opts) when is_list(opts) do
    owner = Keyword.get(opts, :owner)
    name = Keyword.fetch!(opts, :name)
    token = Keyword.fetch!(opts, :token)
    base_url = Keyword.get(opts, :base_url, @default_base_url) || @default_base_url
    command = Keyword.fetch!(opts, :command)
    env = Keyword.get(opts, :env, %{})
    ws_url = ws_url(base_url, name, command, env)

    state = %{
      owner: owner,
      name: name,
      token: token,
      base_url: base_url,
      session_id: nil,
      ws_url: ws_url,
      pending: []
    }

    WebSockex.start_link(
      ws_url,
      __MODULE__,
      state,
      extra_headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  @impl true
  def send(pid, data) when is_pid(pid) do
    WebSockex.send_frame(pid, {:binary, encode_stdin(data)})
  end

  @impl true
  def set_owner(pid, owner) when is_pid(pid) and is_pid(owner) do
    WebSockex.cast(pid, {:set_owner, owner})
  end

  @impl true
  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    _ = kill_remote_session(pid)
    GenServer.stop(pid, :normal, timeout)
  end

  @impl true
  def handle_connect(_conn, state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:set_owner, owner}, state) do
    new_state = flush_pending(%{state | owner: owner, pending: []})

    {:ok, new_state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "session_info"} = message} ->
        new_state =
          state
          |> capture_session_id(message)
          |> queue_or_notify({:message, message})

        {:ok, new_state}

      {:ok, %{"type" => "exit"} = message} ->
        {:ok, queue_or_notify(state, {:message, message})}

      {:ok, message} ->
        {:ok, queue_or_notify(state, {:message, message})}

      {:error, _reason} ->
        {:ok, queue_or_notify(state, {:unparsed_message, payload})}
    end
  end

  def handle_frame({:binary, <<1, payload::binary>>}, state) do
    {:ok, queue_or_notify(state, {:data, payload})}
  end

  def handle_frame({:binary, <<2, payload::binary>>}, state) do
    {:ok, queue_or_notify(state, {:stderr, payload})}
  end

  def handle_frame({:binary, <<3, status, _rest::binary>>}, state) do
    {:ok, queue_or_notify(state, {:exit, {:sprite_exec_exit, status}})}
  end

  def handle_frame(_frame, state) do
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    {:ok, queue_or_notify(state, {:exit, {:sprite_exec_disconnect, reason}})}
  end

  defp encode_stdin(data) do
    <<0>> <> IO.iodata_to_binary(data)
  end

  @doc false
  def ws_url(base_url, name, command, env \\ %{}) do
    uri = URI.parse(base_url)
    scheme = ws_scheme(uri.scheme)
    host = uri.host
    port = if uri.port in [80, 443, nil], do: nil, else: uri.port

    query =
      []
      |> append_repeated("cmd", command)
      |> append_env(env)
      |> Keyword.put(:stdin, "true")
      |> Keyword.put(:tty, "false")
      |> URI.encode_query()

    %URI{
      scheme: scheme,
      host: host,
      port: port,
      path: "/v1/sprites/#{name}/exec",
      query: query
    }
    |> URI.to_string()
  end

  defp ws_scheme("https"), do: "wss"
  defp ws_scheme("http"), do: "ws"
  defp ws_scheme("wss"), do: "wss"
  defp ws_scheme("ws"), do: "ws"
  defp ws_scheme(_), do: "wss"

  defp append_repeated(query, _key, []), do: query
  defp append_repeated(query, key, values), do: query ++ Enum.map(values, &{key, &1})

  defp append_env(query, env) when env == %{}, do: query

  defp append_env(query, env) when is_map(env) do
    query ++ Enum.map(env, fn {key, value} -> {"env", "#{key}=#{value}"} end)
  end

  defp kill_remote_session(pid) do
    state = :sys.get_state(pid)

    if session_id_present?(state.session_id) do
      _ =
        Req.post(
          url: kill_url(state.base_url, state.name, state.session_id),
          headers: [{"authorization", "Bearer #{state.token}"}]
        )

      :ok
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc false
  def kill_url(base_url, name, session_id) do
    uri = URI.parse(base_url)

    %URI{uri | path: "/v1/sprites/#{name}/exec/#{session_id}/kill", query: nil}
    |> URI.to_string()
  end

  defp capture_session_id(state, %{"session_id" => session_id})
       when is_integer(session_id) or (is_binary(session_id) and session_id != "") do
    %{state | session_id: session_id}
  end

  defp capture_session_id(state, _message), do: state

  defp session_id_present?(session_id) when is_integer(session_id), do: true
  defp session_id_present?(session_id) when is_binary(session_id), do: session_id != ""
  defp session_id_present?(_session_id), do: false

  defp queue_or_notify(%{owner: owner} = state, payload) when is_pid(owner) do
    notify_owner(owner, payload)
    state
  end

  defp queue_or_notify(%{pending: pending} = state, payload) do
    %{state | pending: pending ++ [payload]}
  end

  defp flush_pending(%{owner: owner, pending: pending} = state) when is_pid(owner) do
    Enum.each(pending, &notify_owner(owner, &1))
    state
  end

  defp flush_pending(state), do: state

  defp notify_owner(owner, payload) do
    Kernel.send(owner, {:cia_sandbox_channel, self(), payload})
  end
end
