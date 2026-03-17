defmodule CIA.Harness.Codex do
  @moduledoc false

  @behaviour CIA.Harness

  alias CIA.Agent.State
  alias CIA.Harness
  alias CIA.Harness.Codex.Connection

  def runtime_command(%State{harness: harness}) do
    harness
    |> harness_config()
    |> Keyword.get(:command, {"codex", ["app-server", "--listen", "stdio://"]})
  end

  def start_session(%State{} = state) do
    with {:ok, pid} <- Connection.start_link(connection_opts(state)) do
      case do_start_session(pid, state) do
        {:ok, _session, _events} = ok ->
          ok

        {:error, reason} ->
          _ = Connection.stop(pid)
          {:error, reason}
      end
    end
  end

  def stop_session(%Harness{session: %{pid: pid}}) do
    if Process.alive?(pid) do
      Connection.stop(pid)
    else
      :ok
    end
  end

  def start_thread(%Harness{} = harness, opts) when is_list(opts) do
    params =
      %{}
      |> put_if_present("cwd", Keyword.get(opts, :cwd, harness.cwd))
      |> put_if_present("model", Keyword.get(opts, :model))
      |> put_if_present("baseInstructions", Keyword.get(opts, :system_prompt))

    with {:ok, %{"thread" => %{"id" => thread_id}} = response} <-
           Connection.request(session_pid(harness), "thread/start", params, request_timeout(opts)) do
      {:ok, %{id: thread_id, response: response}}
    end
  end

  def resume_thread(%Harness{} = harness, thread_or_id) do
    params =
      %{"threadId" => thread_id(thread_or_id)}
      |> put_if_present("cwd", harness.cwd)
      |> put_if_present("approvalPolicy", "never")

    with {:ok, %{"thread" => %{"id" => thread_id}} = response} <-
           Connection.request(session_pid(harness), "thread/resume", params) do
      {:ok, %{id: thread_id, response: response}}
    end
  end

  def submit_turn(%Harness{} = harness, thread_ref, input, opts) when is_list(opts) do
    params =
      %{
        "threadId" => thread_id(thread_ref),
        "input" => normalize_input(input)
      }
      |> put_if_present("cwd", Keyword.get(opts, :cwd, harness.cwd))
      |> put_if_present("model", Keyword.get(opts, :model))
      |> put_if_present("effort", Keyword.get(opts, :reasoning_effort))
      |> put_if_present("serviceTier", Keyword.get(opts, :service_tier))
      |> put_if_present("approvalPolicy", Keyword.get(opts, :approval_policy, "never"))
      |> put_if_present("sandboxPolicy", Keyword.get(opts, :sandbox_policy))

    with {:ok, %{"turn" => %{"id" => turn_id}} = response} <-
           Connection.request(session_pid(harness), "turn/start", params, request_timeout(opts)) do
      {:ok, %{id: turn_id, thread_id: thread_id(thread_ref), response: response}}
    end
  end

  def steer_turn(%Harness{} = harness, turn_ref, input, opts) when is_list(opts) do
    turn_id = turn_ref.id

    params = %{
      "threadId" => turn_ref.thread_id,
      "expectedTurnId" => turn_id,
      "input" => normalize_input(input)
    }

    with {:ok, %{"turnId" => ^turn_id}} <-
           Connection.request(session_pid(harness), "turn/steer", params, request_timeout(opts)) do
      :ok
    end
  end

  def cancel_turn(%Harness{} = harness, turn_ref) do
    params = %{
      "threadId" => turn_ref.thread_id,
      "turnId" => turn_ref.id
    }

    case Connection.request(session_pid(harness), "turn/interrupt", params) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp connection_opts(%State{sandbox: sandbox}) do
    case sandbox do
      %{channel: channel} when not is_nil(channel) ->
        [owner: self(), channel: channel]

      _ ->
        raise "sandbox is missing a live channel"
    end
  end

  defp initialize_params do
    %{
      "clientInfo" => %{
        "name" => "cia",
        "version" => Application.spec(:cia, :vsn) |> to_string()
      },
      "capabilities" => %{
        "experimentalApi" => true
      }
    }
  end

  defp ensure_authenticated(pid, auth) do
    with {:ok, %{"account" => account, "requiresOpenaiAuth" => requires_auth}} <-
           Connection.request(pid, "account/read", %{"refreshToken" => false}) do
      cond do
        account != nil ->
          :ok

        requires_auth ->
          login_with_auth(pid, auth)

        true ->
          :ok
      end
    end
  end

  defp login_with_auth(_pid, nil), do: {:error, :auth_required}

  defp login_with_auth(pid, auth) do
    with {:ok, params} <- auth_params(auth),
         {:ok, response} <- Connection.request(pid, "account/login/start", params),
         :ok <- handle_login_response(response),
         {:ok, %{"account" => account}} <-
           Connection.request(pid, "account/read", %{"refreshToken" => false}),
         true <- not is_nil(account) do
      :ok
    else
      false -> {:error, :auth_required}
      {:error, _reason} = error -> error
    end
  end

  defp auth_params(api_key) when is_binary(api_key) and api_key != "" do
    {:ok, %{"type" => "apiKey", "apiKey" => api_key}}
  end

  defp auth_params({:api_key, api_key}), do: auth_params(api_key)

  defp auth_params(%{type: :api_key, api_key: api_key}), do: auth_params(api_key)
  defp auth_params(%{type: "apiKey", apiKey: api_key}), do: auth_params(api_key)
  defp auth_params(%{"type" => "apiKey", "apiKey" => api_key}), do: auth_params(api_key)

  defp auth_params(:chatgpt), do: {:ok, %{"type" => "chatgpt"}}
  defp auth_params(%{type: :chatgpt}), do: {:ok, %{"type" => "chatgpt"}}
  defp auth_params(%{"type" => "chatgpt"}), do: {:ok, %{"type" => "chatgpt"}}

  defp auth_params(other), do: {:error, {:invalid_auth, other}}

  defp handle_login_response(%{"type" => "apiKey"}), do: :ok
  defp handle_login_response(%{"type" => "chatgptAuthTokens"}), do: :ok

  defp handle_login_response(%{"type" => "chatgpt", "authUrl" => auth_url, "loginId" => login_id}) do
    {:error, {:interactive_login_required, %{auth_url: auth_url, login_id: login_id}}}
  end

  defp handle_login_response(other), do: {:error, {:unexpected_login_response, other}}

  defp do_start_session(pid, %State{} = state) do
    with %Harness{} = harness <- state.harness,
         {:ok, _response} <- Connection.request(pid, "initialize", initialize_params()),
         :ok <- Connection.notify(pid, "initialized", nil),
         :ok <- ensure_authenticated(pid, state.auth) do
      {:ok, %{harness | cwd: workspace_root(state), session: %{pid: pid}}, []}
    end
  end

  defp normalize_input(input) when is_binary(input) do
    [%{"type" => "text", "text" => input}]
  end

  defp normalize_input(input) when is_map(input) do
    [stringify_map(input)]
  end

  defp normalize_input(input) when is_list(input) do
    Enum.map(input, fn
      value when is_binary(value) -> %{"type" => "text", "text" => value}
      value when is_map(value) -> stringify_map(value)
    end)
  end

  defp normalize_input(other) do
    raise ArgumentError, "unsupported Codex input: #{inspect(other)}"
  end

  defp stringify_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} -> {key, stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp request_timeout(opts), do: Keyword.get(opts, :timeout, 30_000)

  defp harness_config(%CIA.Harness{config: config}) when is_map(config), do: Map.to_list(config)
  defp harness_config(_), do: []

  defp session_pid(%Harness{session: %{pid: pid}}) when is_pid(pid), do: pid

  defp workspace_root(%State{workspace: %{root: root}}), do: root
  defp workspace_root(_), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp thread_id(%{id: id}) when is_binary(id), do: id
  defp thread_id(id) when is_binary(id), do: id
end
