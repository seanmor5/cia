# CIA - Central Intelligence Agent

Manage background agents directly in your Elixir app.

## Overview

CIA is an opinionated library for running background agents from an Elixir app.

It separates two runtime concerns:

- the sandbox: where that agent is running
- the workspace: what filesystem scope that work should happen in
- the harness: what agent implementation is running

And it manages three core runtime models:

- agents: a single running managed agent
- threads: a conversation handle owned by an agent
- turns: a single unit of model work on a thread

Each agent runs as a GenServer. CIA can start agents directly or under your own
supervisor. Right now, CIA is entirely in-memory. Agent, thread, and turn state
does not survive application restarts.

## Installation

Install from GitHub for now:

```elixir
def deps do
  [
    {:cia, github: "seanmor5/cia"}
  ]
end
```

## Documentation

Generate docs locally with:

```sh
mix docs
```

Livebook guides live in `guides/` and are published as part of the generated
docs.

Run the docs pipeline with warnings treated as errors:

```sh
mix docs --warnings-as-errors
```

## Usage

```elixir
openai_api_key = System.fetch_env!("OPENAI_API_KEY")

config =
  CIA.new()
  |> CIA.sandbox(:local)
  |> CIA.workspace(:directory, root: "/sandbox")
  |> CIA.before_start(fn %{sandbox: sandbox} ->
    with {:ok, _} <- CIA.exec(sandbox, ["mkdir", "-p", "/sandbox"]) do
      :ok
    end
  end)
  |> CIA.harness(:codex, auth: {:api_key, openai_api_key})

{:ok, agent} = CIA.start(config)
```

`CIA.start/1` consumes the built configuration. Sandbox, workspace, and harness
configuration all flow through it.

`CIA.before_start/2` is the hook for deterministic startup configuration.
It runs after the sandbox starts but before the harness session is started,
so it is the right place to create directories, write seed files, or sync code
before Codex begins handling turns.

To start an agent under your own supervisor instead:

```elixir
{:ok, agent} = CIA.start(config, supervisor: MyApp.CIAAgentSupervisor)
```

Today, the supported workspace kind is `:directory`.
The `before_start` hook runs after sandbox start and before workspace and harness
startup. If it returns anything other than `:ok`, startup is rolled back and
`CIA.start/1` returns an error.

After startup, create a thread and submit a turn:

```elixir
:ok = CIA.subscribe(agent)

{:ok, thread} =
  CIA.thread(agent,
    cwd: "/sandbox",
    model: "gpt-5.4"
  )

{:ok, turn} =
  CIA.turn(agent, thread, "Create lib/demo.ex with a function that returns :ok.")
```

For local Codex runs, if the `codex` binary is not on the BEAM process `PATH`,
pass an absolute command path:

```elixir
|> CIA.harness(:codex,
  command: {"/opt/homebrew/bin/codex", ["app-server", "--listen", "stdio://"]},
  auth: {:api_key, openai_api_key}
)
```

## Events

CIA supports agent-level subscriptions through `subscribe/2`.

Subscribers currently receive messages in this form:

```elixir
{:cia, %CIA.Agent{}, event}
```

The current event stream forwards harness-originated events from the running
agent process, for example:

```elixir
{:cia, agent, {:harness, :codex, payload}}
```

Subscriptions are for all agent events.

## Supported Harnesses

CIA currently just supports codex via it's app-server implementation.

## Supported Sandboxes

CIA currently supports `:local` and `:sprite` (see [Sprite](https://sprite.dev)) based sandboxes.
