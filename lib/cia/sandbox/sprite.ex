defmodule CIA.Sandbox.Sprite do
  @moduledoc false

  @behaviour CIA.Sandbox

  alias CIA.Sandbox.Channel
  alias CIA.Sandbox.Sprite.Channel.Exec

  @default_base_url "https://api.sprites.dev"

  defstruct [
    :name,
    :token,
    :channel,
    mode: :workspace_write,
    base_url: @default_base_url,
    metadata: %{}
  ]

  def start(%CIA.Sandbox{provider: provider, config: config, metadata: metadata}, opts)
      when provider in [:sprite, :sprites] and is_list(opts) do
    opts =
      config
      |> Map.to_list()
      |> Keyword.merge(opts)
      |> Keyword.put_new(:metadata, metadata)

    mode = Keyword.get(opts, :mode, :workspace_write)

    command =
      opts
      |> Keyword.fetch!(:command)
      |> normalize_runtime_command()

    metadata = Keyword.get(opts, :metadata, %{})
    env = Keyword.get(opts, :env, %{})
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    checkpoint = Keyword.get(opts, :checkpoint)

    with {:ok, name} <- validate_name(Keyword.get(opts, :name)),
         {:ok, token} <- validate_token(Keyword.get(opts, :token)),
         :ok <- ensure_sprite_exists(base_url, name, token),
         :ok <- maybe_restore_checkpoint(base_url, name, token, checkpoint),
         {:ok, pid} <-
           Exec.start_link(
             name: name,
             token: token,
             base_url: base_url,
             command: command,
             env: env
           ) do
      {:ok,
       %__MODULE__{
         name: name,
         token: token,
         base_url: base_url,
         mode: mode,
         channel: Channel.new(Exec, pid),
         metadata: metadata
       }}
    end
  end

  def stop(%__MODULE__{channel: %Channel{} = channel}) do
    :ok = Channel.stop(channel)
    :ok
  end

  def exec(%__MODULE__{} = sandbox, command, opts) when is_list(command) and is_list(opts) do
    cwd = Keyword.get(opts, :cwd)
    env = Keyword.get(opts, :env, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Req.post(
           url: exec_url(sandbox.base_url, sandbox.name, command, cwd, env),
           headers: auth_headers(sandbox.token),
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        with {:ok, output} <- decode_exec_output(body) do
          case output do
            %{exit_code: 0} -> {:ok, output}
            %{exit_code: _status} -> {:error, {:command_failed, output}}
          end
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_exec_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_exec_failed, reason}}
    end
  end

  defp normalize_runtime_command({command, args})
       when is_binary(command) and is_list(args),
       do: [command | args]

  defp normalize_runtime_command(command) when is_list(command), do: command

  defp validate_name(name) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp validate_name(_), do: {:error, {:missing_option, :name}}

  defp validate_token(token) when is_binary(token) and byte_size(token) > 0, do: {:ok, token}
  defp validate_token(_), do: {:error, {:missing_option, :token}}

  defp ensure_sprite_exists(base_url, name, token) do
    case fetch_sprite(base_url, name, token) do
      {:ok, _body} ->
        :ok

      {:missing, _body} ->
        create_sprite(base_url, name, token)

      {:error, {:status, status, body}} ->
        {:error, {:sprite_lookup_failed, status, body}}

      {:error, reason} ->
        {:error, {:sprite_lookup_failed, reason}}
    end
  end

  defp fetch_sprite(base_url, name, token) do
    case Req.get(url: sprite_url(base_url, name), headers: auth_headers(token)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:missing, decode_error_body(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_sprite(base_url, name, token) do
    case Req.post(
           url: sprites_url(base_url),
           headers: auth_headers(token),
           json: %{name: name}
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        decoded = decode_error_body(body)
        {:error, {:sprite_create_failed, status, decoded}}

      {:error, reason} ->
        {:error, {:sprite_create_failed, reason}}
    end
  end

  defp maybe_restore_checkpoint(_base_url, _name, _token, nil), do: :ok

  defp maybe_restore_checkpoint(base_url, name, token, checkpoint)
       when is_binary(checkpoint) and byte_size(checkpoint) > 0 do
    case Req.post(
           url: checkpoint_restore_url(base_url, name, checkpoint),
           headers: auth_headers(token)
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case decode_checkpoint_restore_body(body) do
          {:ok, _decoded} -> :ok
          {:error, _reason} -> :ok
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:sprite_checkpoint_restore_failed, status, decode_error_body(body)}}

      {:error, reason} ->
        {:error, {:sprite_checkpoint_restore_failed, reason}}
    end
  end

  defp maybe_restore_checkpoint(_base_url, _name, _token, checkpoint) do
    {:error, {:invalid_option, {:checkpoint, checkpoint}}}
  end

  defp checkpoint_restore_url(base_url, name, checkpoint) do
    uri = URI.parse(base_url)

    %URI{
      uri
      | path: "/v1/sprites/#{name}/checkpoints/#{checkpoint}/restore",
        query: nil
    }
    |> URI.to_string()
  end

  defp sprite_url(base_url, name) do
    uri = URI.parse(base_url)

    %URI{uri | path: "/v1/sprites/#{name}", query: nil}
    |> URI.to_string()
  end

  defp sprites_url(base_url) do
    uri = URI.parse(base_url)

    %URI{uri | path: "/v1/sprites", query: nil}
    |> URI.to_string()
  end

  defp exec_url(base_url, name, command, cwd, env) do
    uri = URI.parse(base_url)

    query =
      []
      |> append_repeated("cmd", command)
      |> maybe_put("dir", cwd)
      |> append_env(env)
      |> URI.encode_query()

    %URI{uri | path: "/v1/sprites/#{name}/exec", query: query}
    |> URI.to_string()
  end

  defp decode_checkpoint_restore_body(""), do: {:ok, nil}
  defp decode_checkpoint_restore_body(nil), do: {:ok, nil}
  defp decode_checkpoint_restore_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_checkpoint_restore_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        decode_ndjson_body(body)
    end
  end

  defp decode_ndjson_body(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_error_body(body) when is_map(body) or is_list(body), do: body

  defp decode_error_body(body) when is_binary(body) do
    case decode_checkpoint_restore_body(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_exec_output(<<3, status, _rest::binary>>) when is_integer(status) do
    {:ok, %{stdout: "", stderr: "", exit_code: status}}
  end

  defp decode_exec_output(body) when is_binary(body) do
    with {:ok, decoded} <- decode_checkpoint_restore_body(body),
         {:ok, exit_code} <- extract_exit_code(decoded) do
      {:ok,
       %{
         stdout: extract_output(decoded, "stdout"),
         stderr: extract_output(decoded, "stderr"),
         exit_code: exit_code
       }}
    end
  end

  defp extract_exit_code(%{"exit_code" => exit_code}) when is_integer(exit_code),
    do: {:ok, exit_code}

  defp extract_exit_code(%{"exitCode" => exit_code}) when is_integer(exit_code),
    do: {:ok, exit_code}

  defp extract_exit_code(%{exit_code: exit_code}) when is_integer(exit_code), do: {:ok, exit_code}
  defp extract_exit_code(%{exitCode: exit_code}) when is_integer(exit_code), do: {:ok, exit_code}
  defp extract_exit_code(other), do: {:error, {:invalid_sprite_exec_response, other}}

  defp extract_output(map, key) when is_map(map) do
    case key do
      "stdout" -> Map.get(map, "stdout") || Map.get(map, :stdout) || ""
      "stderr" -> Map.get(map, "stderr") || Map.get(map, :stderr) || ""
    end
  end

  defp append_repeated(query, _key, []), do: query
  defp append_repeated(query, key, values), do: query ++ Enum.map(values, &{key, &1})

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, String.to_atom(key), value)

  defp append_env(query, env) when env == %{}, do: query

  defp append_env(query, env) when is_map(env),
    do: query ++ Enum.map(env, fn {key, value} -> {"env", "#{key}=#{value}"} end)

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]
  end
end
