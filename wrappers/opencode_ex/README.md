# OpencodeEx

Elixir wrapper for the OpenCode HTTP agent SDK. Provides idiomatic Elixir access
to the OpenCode HTTP REST + SSE transport with lazy streaming via
`Stream.resource/3`.

OpenCode exposes a richer API surface than port-based adapters, including session
management, permission handling, and server health checks.

## Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [{:opencode_ex, path: "wrappers/opencode_ex"}]
end
```

## Quick Start

```elixir
# Start the OpenCode server first: opencode serve

{:ok, session} = OpencodeEx.start_session(
  base_url: "http://localhost:4096",
  directory: "/my/project"
)
{:ok, messages} = OpencodeEx.query(session, "Explain this codebase")
OpencodeEx.stop(session)
```

## API Reference

### Session Lifecycle

```elixir
OpencodeEx.start_session(opts) :: {:ok, pid()} | {:error, term()}
OpencodeEx.stop(session) :: :ok
OpencodeEx.health(session) :: atom()
```

### Querying

```elixir
OpencodeEx.query(session, prompt, params \\ %{}) :: {:ok, [map()]} | {:error, term()}
OpencodeEx.abort(session) :: :ok | {:error, term()}
```

`query/2,3` is blocking (default 120s). `abort/1` cancels the active query.

### Streaming

```elixir
OpencodeEx.stream!(session, prompt, params \\ %{}) :: Enumerable.t()
OpencodeEx.stream(session, prompt, params \\ %{}) :: Enumerable.t()
```

`stream!/3` raises on errors; `stream/3` returns ok/error tuples.

### Session Info & Runtime Control

```elixir
OpencodeEx.session_info(session) :: {:ok, map()} | {:error, term()}
OpencodeEx.set_model(session, model) :: {:ok, term()} | {:error, term()}
```

### SDK Hooks

```elixir
OpencodeEx.sdk_hook(event, callback) :: map()
OpencodeEx.sdk_hook(event, callback, matcher) :: map()
```

### Supervisor Integration

```elixir
OpencodeEx.child_spec(opts) :: Supervisor.child_spec()
```

### OpenCode-Specific Operations

```elixir
OpencodeEx.list_sessions(session) :: {:ok, [map()]} | {:error, term()}
OpencodeEx.get_session(session, id) :: {:ok, map()} | {:error, term()}
OpencodeEx.delete_session(session, id) :: {:ok, term()} | {:error, term()}
OpencodeEx.send_command(session, command, params \\ %{}) :: {:ok, term()} | {:error, term()}
OpencodeEx.server_health(session) :: {:ok, map()} | {:error, term()}
```

## Session Options

Accepts keyword lists or maps:

```elixir
OpencodeEx.start_session(
  base_url: "http://localhost:4096",  # OpenCode server URL
  directory: "/my/project",           # Workspace directory (required)
  auth: {:basic, "user", "pass"},     # HTTP Basic Auth (optional)
  model_id: "claude-sonnet-4-20250514",
  provider_id: "anthropic",
  agent: "coder",                      # OpenCode agent name
  permission_handler: &my_handler/3,   # Permission callback
  sdk_hooks: [hook1]
)
```

## Permission Handling

OpenCode uses a **fail-closed** permission model. When no `permission_handler`
is set, all permission requests are automatically **denied**.

```elixir
# Approve all permissions (use with caution)
handler = fn _perm_id, _metadata, _opts -> {:allow, %{}} end

{:ok, session} = OpencodeEx.start_session(
  directory: "/my/project",
  permission_handler: handler
)

# Selective approval
handler = fn _perm_id, %{"tool" => tool}, _opts ->
  case tool do
    "read" -> {:allow, %{}}
    "write" -> {:allow, %{}}
    "shell" -> {:deny, "Shell access denied"}
    _ -> {:deny, "Unknown tool"}
  end
end
```

## Examples

### Streaming

```elixir
session
|> OpencodeEx.stream!("Explain this module")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :tool_use -> IO.puts("\nTool: #{msg.tool_name}")
    :thinking -> IO.puts("\n[Thinking: #{msg.content}]")
    :result -> IO.puts("\n--- Complete ---")
    _ -> :ok
  end
end)
```

### HTTP Basic Auth

```elixir
{:ok, session} = OpencodeEx.start_session(
  base_url: "http://localhost:4096",
  directory: "/my/project",
  auth: {:basic, "admin", "secret"}
)
```

### Session Management

```elixir
# List all sessions on the server
{:ok, sessions} = OpencodeEx.list_sessions(session)

# Get details for a specific session
{:ok, detail} = OpencodeEx.get_session(session, "session-id-here")

# Delete a session
{:ok, _} = OpencodeEx.delete_session(session, "old-session-id")
```

### Sending Commands

```elixir
{:ok, _} = OpencodeEx.send_command(session, "/compact")
```

### Server Health

```elixir
{:ok, health} = OpencodeEx.server_health(session)
```

### Aborting a Query

```elixir
# Start a long query in another process
Task.async(fn -> OpencodeEx.query(session, "Refactor the entire codebase") end)

# Abort after 5 seconds
Process.sleep(5_000)
:ok = OpencodeEx.abort(session)
```

### Non-Raising Stream

```elixir
session
|> OpencodeEx.stream("Risky query")
|> Enum.each(fn
  {:ok, msg} -> IO.inspect(msg.type)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end)
```

## Intentional Omissions & Workarounds

The OpenCode server exposes a large REST API surface. This wrapper covers
the most common operations. For anything not covered:

```elixir
# Send arbitrary commands
OpencodeEx.send_command(session, "command_name", %{"param" => "value"})

# Direct gen_statem calls
:gen_statem.call(session, {:custom_op, args}, 5_000)
```

### OpenCode Server APIs Not Wrapped

| OpenCode API | Workaround |
|-------------|------------|
| PTY (terminal) | Not applicable for SDK use |
| File operations | Use agent tool calls instead |
| Config management | Configure via opencode CLI |
| Provider auth | Configure via opencode CLI |
| Session sharing/fork/diff | Use `get_session/2` + app logic |
| Session summarize | Use `send_command/3` |
| MCP server management | Configure via opencode CLI |

See the [opencode_client README](../../../apps/opencode_client/README.md)
for the full omissions table.
