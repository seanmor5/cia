defmodule CIA.Harness.Codex.Connection do
  @moduledoc false

  use GenServer

  alias CIA.Sandbox.Channel

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def request(pid, method, params, timeout \\ 5_000) when is_pid(pid) and is_binary(method) do
    GenServer.call(pid, {:request, method, params}, timeout)
  end

  def notify(pid, method, params \\ nil, timeout \\ 5_000)
      when is_pid(pid) and is_binary(method) do
    GenServer.call(pid, {:notify, method, params}, timeout)
  end

  def stop(pid, timeout \\ 5_000) when is_pid(pid) do
    GenServer.stop(pid, :normal, timeout)
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    channel = Keyword.fetch!(opts, :channel)

    with :ok <- Channel.set_owner(channel, self()) do
      {:ok,
       %{
         channel: channel,
         owner: owner,
         buffer: "",
         next_id: 1,
         pending: %{}
       }}
    end
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    id = state.next_id

    message =
      %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method
      }
      |> maybe_put_params(params)

    with :ok <- send_message(state.channel, message) do
      {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    message =
      %{
        "jsonrpc" => "2.0",
        "method" => method
      }
      |> maybe_put_params(params)

    case send_message(state.channel, message) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(
        {:cia_sandbox_channel, pid, {:data, data}},
        %{channel: %Channel{pid: pid}} = state
      ) do
    {messages, buffer} = extract_messages(state.buffer <> data)

    new_state =
      Enum.reduce(messages, %{state | buffer: buffer}, fn message, acc ->
        handle_message(message, acc)
      end)

    {:noreply, new_state}
  end

  def handle_info(
        {:cia_sandbox_channel, pid, {:stderr, data}},
        %{channel: %Channel{pid: pid}} = state
      ) do
    notify_owner(state.owner, {:stderr, data})
    {:noreply, state}
  end

  def handle_info(
        {:cia_sandbox_channel, pid, {:message, message}},
        %{channel: %Channel{pid: pid}} = state
      ) do
    notify_owner(state.owner, {:channel_message, message})
    {:noreply, state}
  end

  def handle_info(
        {:cia_sandbox_channel, pid, {:unparsed_message, message}},
        %{channel: %Channel{pid: pid}} = state
      ) do
    notify_owner(state.owner, {:unparsed_channel_message, message})
    {:noreply, state}
  end

  def handle_info(
        {:cia_sandbox_channel, pid, {:exit, reason}},
        %{channel: %Channel{pid: pid}} = state
      ) do
    notify_owner(state.owner, {:transport_exit, reason})
    fail_pending(state.pending, reason)
    {:stop, reason, %{state | pending: %{}}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp send_message(channel, message) do
    encoded = Jason.encode!(message) <> "\n"
    Channel.send(channel, encoded)
  end

  defp maybe_put_params(message, nil), do: message
  defp maybe_put_params(message, params), do: Map.put(message, "params", params)

  defp extract_messages(buffer) do
    parts = String.split(buffer, "\n")
    complete = Enum.drop(parts, -1)
    remainder = List.last(parts) || ""

    messages =
      complete
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))

    {messages, remainder}
  end

  defp handle_message(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "result" => result}} when is_integer(id) ->
        reply_and_drop_pending(state, id, {:ok, result})

      {:ok, %{"id" => id, "error" => error}} when is_integer(id) ->
        reply_and_drop_pending(state, id, {:error, normalize_error(error)})

      {:ok, %{"method" => method, "params" => params} = message} ->
        notify_owner(
          state.owner,
          {:server_message, %{method: method, params: params, message: message}}
        )

        state

      {:ok, %{"method" => method} = message} ->
        notify_owner(
          state.owner,
          {:server_message, %{method: method, params: nil, message: message}}
        )

        state

      {:error, _reason} ->
        notify_owner(state.owner, {:unparsed_message, line})
        state

      _ ->
        state
    end
  end

  defp reply_and_drop_pending(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {from, pending} ->
        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp fail_pending(pending, reason) do
    Enum.each(pending, fn {_id, from} ->
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp normalize_error(%{"code" => code, "message" => message} = error) do
    data = Map.get(error, "data")
    %{code: code, message: message, data: data}
  end

  defp notify_owner(owner, payload) do
    send(owner, {:cia_harness, :codex, payload})
  end
end
