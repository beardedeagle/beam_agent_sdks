# CodexEx

Elixir wrapper for the Codex CLI agent SDK. Provides idiomatic Elixir access
to the Codex app-server and one-shot transports with lazy streaming via
`Stream.resource/3`.

## Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [{:codex_ex, path: "wrappers/codex_ex"}]
end
```

## Quick Start

```elixir
# App-server transport (full features)
{:ok, session} = CodexEx.start_session(cli_path: "codex")
{:ok, messages} = CodexEx.query(session, "What is 2+2?")
CodexEx.stop(session)

# One-shot transport (simpler, stateless)
{:ok, oneshot} = CodexEx.start_exec(cli_path: "codex")
{:ok, messages} = CodexEx.query(oneshot, "Explain closures")
CodexEx.stop(oneshot)
```

Note: `start_exec/1` calls `:codex_exec.start_link/1` under the hood.

## API Reference

### Session Lifecycle

```elixir
CodexEx.start_session(opts) :: {:ok, pid()} | {:error, term()}  # app-server
CodexEx.start_exec(opts) :: {:ok, pid()} | {:error, term()}      # one-shot (codex_exec)
CodexEx.stop(session) :: :ok
CodexEx.health(session) :: atom()
```

### Querying

```elixir
CodexEx.query(session, prompt, params \\ %{}) :: {:ok, [map()]} | {:error, term()}
```

Blocking. Works with both transports. Default timeout: 120s.

### Streaming

```elixir
CodexEx.stream!(session, prompt, params \\ %{}) :: Enumerable.t()
CodexEx.stream(session, prompt, params \\ %{}) :: Enumerable.t()
```

`stream!/3` raises on errors; `stream/3` returns ok/error tuples.

### Thread Management (App-server Only)

```elixir
CodexEx.thread_start(session, opts \\ %{}) :: {:ok, map()} | {:error, term()}
CodexEx.thread_resume(session, thread_id) :: {:ok, map()} | {:error, term()}
CodexEx.thread_list(session) :: {:ok, [map()]} | {:error, term()}
```

Returns `{:error, :not_supported}` for one-shot sessions.

### Session Info and Runtime Control

```elixir
CodexEx.session_info(session) :: {:ok, map()} | {:error, term()}
CodexEx.set_model(session, model) :: {:ok, term()} | {:error, term()}
CodexEx.interrupt(session) :: :ok | {:error, term()}
```

### SDK Hooks

```elixir
CodexEx.sdk_hook(event, callback) :: map()
CodexEx.sdk_hook(event, callback, matcher) :: map()
```

### Supervisor Integration

```elixir
CodexEx.child_spec(opts) :: Supervisor.child_spec()
```

## Session Options

Accepts keyword lists or maps:

```elixir
CodexEx.start_session(
  cli_path: "codex",
  work_dir: "/my/project",
  transport: :app_server,
  model: "codex-mini-latest",
  approval_policy: "full-auto",
  sandbox_mode: "docker",
  base_instructions: "Always explain your reasoning",
  thread_id: "thread_abc123",
  sdk_hooks: [hook1]
)
```

## Examples

### Thread Management

```elixir
{:ok, session} = CodexEx.start_session(cli_path: "codex")

# Start a new thread
{:ok, %{"threadId" => tid}} = CodexEx.thread_start(session)

# Query in that thread
{:ok, msgs} = CodexEx.query(session, "Define a Fibonacci function")

# List all threads
{:ok, threads} = CodexEx.thread_list(session)
```

### Streaming

```elixir
session
|> CodexEx.stream!("Explain pattern matching")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :tool_use -> IO.puts("\nTool: #{msg.tool_name}")
    :result -> IO.puts("\n--- Complete ---")
    _ -> :ok
  end
end)
```

### Hook Example

```elixir
hook = CodexEx.sdk_hook(:post_tool_use, fn ctx ->
  IO.puts("Tool used: #{Map.get(ctx, :tool_name, "unknown")}")
  :ok
end)
{:ok, session} = CodexEx.start_session(cli_path: "codex", sdk_hooks: [hook])
```

## Intentional Omissions and Workarounds

This wrapper delegates to the Erlang `codex_app_server` facade. For features
not directly wrapped:

```elixir
# Send arbitrary control messages (app-server only)
:codex_session.send_control(session, "method", %{})

# Direct gen_statem calls
:gen_statem.call(session, {:custom_op, args}, 5_000)
```

See the [codex_app_server README](../../../apps/codex_app_server/README.md)
for the full omissions table.

## Note on Function Names

The actual Elixir API uses `start_exec/1` (matching the Erlang `codex_exec`
module name). This README uses "one-shot" terminology for clarity. The function
signatures are:

- `CodexEx.start_session/1` -- starts `codex_session` (app-server transport)
- `CodexEx.start_exec/1` -- starts `codex_exec` (one-shot JSONL transport)
