# GeminiEx

Elixir wrapper for the Gemini CLI agent SDK. Provides idiomatic Elixir access
to the Gemini CLI transport with lazy streaming via `Stream.resource/3`.

Each query spawns a new port process (one-shot JSONL). Session IDs are captured
from init events and automatically reused via `--resume` for subsequent queries.

## Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [{:gemini_ex, path: "wrappers/gemini_ex"}]
end
```

## Quick Start

```elixir
{:ok, session} = GeminiEx.start_session(cli_path: "gemini")
{:ok, messages} = GeminiEx.query(session, "What is 2+2?")
GeminiEx.stop(session)
```

## API Reference

### Session Lifecycle

```elixir
GeminiEx.start_session(opts) :: {:ok, pid()} | {:error, term()}
GeminiEx.stop(session) :: :ok
GeminiEx.health(session) :: atom()
```

### Querying

```elixir
GeminiEx.query(session, prompt, params \\ %{}) :: {:ok, [map()]} | {:error, term()}
```

Blocking. Default timeout: 120s.

### Streaming

```elixir
GeminiEx.stream!(session, prompt, params \\ %{}) :: Enumerable.t()
GeminiEx.stream(session, prompt, params \\ %{}) :: Enumerable.t()
```

`stream!/3` raises on errors; `stream/3` returns ok/error tuples.

### Session Info & Runtime Control

```elixir
GeminiEx.session_info(session) :: {:ok, map()} | {:error, term()}
GeminiEx.set_model(session, model) :: {:ok, term()} | {:error, term()}
GeminiEx.interrupt(session) :: :ok | {:error, term()}
```

### SDK Hooks

```elixir
GeminiEx.sdk_hook(event, callback) :: map()
GeminiEx.sdk_hook(event, callback, matcher) :: map()
```

### Supervisor Integration

```elixir
GeminiEx.child_spec(opts) :: Supervisor.child_spec()
```

## Session Options

Accepts keyword lists or maps:

```elixir
GeminiEx.start_session(
  cli_path: "gemini",
  work_dir: "/my/project",
  model: "gemini-2.5-pro",
  approval_mode: "yolo",            # yolo, default, auto_edit, plan
  settings_file: "/path/to/settings.json",
  env: [{"GEMINI_API_KEY", "..."}],
  sdk_hooks: [hook1]
)
```

## Examples

### Streaming

```elixir
session
|> GeminiEx.stream!("Explain pattern matching in Elixir")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :tool_use -> IO.puts("\nTool: #{msg.tool_name}")
    :result -> IO.puts("\n--- Complete ---")
    _ -> :ok
  end
end)
```

### Session Resume (Automatic)

```elixir
{:ok, session} = GeminiEx.start_session(cli_path: "gemini")

# First query captures session_id from init event
{:ok, _} = GeminiEx.query(session, "Define a helper function")

# Second query automatically passes --resume with the captured session_id
{:ok, _} = GeminiEx.query(session, "Now add error handling to it")
```

### Model Override Per Query

```elixir
{:ok, _} = GeminiEx.query(session, "Quick question", %{
  model: "gemini-2.5-flash"
})
```

### Hook Example

```elixir
hook = GeminiEx.sdk_hook(:post_tool_use, fn ctx ->
  IO.puts("Gemini used tool: #{Map.get(ctx, :tool_name, "unknown")}")
  :ok
end)
{:ok, session} = GeminiEx.start_session(cli_path: "gemini", sdk_hooks: [hook])
```

### Non-Raising Stream

```elixir
session
|> GeminiEx.stream("Risky query")
|> Enum.each(fn
  {:ok, msg} -> IO.inspect(msg.type)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end)
```

## Intentional Omissions & Workarounds

The Gemini CLI is **unidirectional** (stdout only). There is no bidirectional
control protocol, no `send_control/3`, and no in-process MCP server support.

### No MCP Servers

The Gemini CLI does not support SDK MCP servers. The `sdk_mcp_servers` option
is ignored.

### Features Available via extra_args

Any CLI flags not covered by named options:

```elixir
GeminiEx.start_session(
  cli_path: "gemini",
  extra_args: %{"--sandbox" => "true", "--verbose" => nil}
)
```

See the [gemini_cli_client README](../../apps/gemini_cli_client/README.md)
for the full omissions table.

## Shared Foundation

MCP servers, lifecycle hooks, content blocks, and telemetry are provided by
[AgentWire](../agent_wire_ex/README.md) — the shared Elixir foundation used
by all five adapter wrappers.
