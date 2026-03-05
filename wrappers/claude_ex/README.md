# ClaudeEx

Elixir wrapper for the Claude Code agent SDK. Provides idiomatic Elixir access
to `claude_agent_session` with lazy streaming via `Stream.resource/3`.

## Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [{:claude_ex, path: "wrappers/claude_ex"}]
end
```

## Quick Start

```elixir
# Start a session
{:ok, session} = ClaudeEx.start_session(cli_path: "/usr/local/bin/claude")

# Blocking query
{:ok, messages} = ClaudeEx.query(session, "What is 2+2?")

# Streaming query (lazy)
session
|> ClaudeEx.stream!("Explain OTP supervision trees")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :result -> IO.puts("\n--- Done ---")
    _ -> :ok
  end
end)

ClaudeEx.stop(session)
```

## API Reference

### Session Lifecycle

```elixir
ClaudeEx.start_session(opts) :: {:ok, pid()} | {:error, term()}
ClaudeEx.stop(session) :: :ok
ClaudeEx.health(session) :: atom()
```

### Querying

```elixir
ClaudeEx.query(session, prompt, params \\ %{}) :: {:ok, [map()]} | {:error, term()}
```

Blocking. Collects all messages until result/error. Default timeout: 120s.

### Streaming

```elixir
# Raises on errors
ClaudeEx.stream!(session, prompt, params \\ %{}) :: Enumerable.t()

# Returns {:ok, msg} / {:error, reason} tuples
ClaudeEx.stream(session, prompt, params \\ %{}) :: Enumerable.t()
```

Both return lazy `Stream.resource/3` enumerables. `stream!/3` raises on errors;
`stream/3` wraps each element in ok/error tuples.

### Session Info & Runtime Control

```elixir
ClaudeEx.session_info(session) :: {:ok, map()} | {:error, term()}
ClaudeEx.set_model(session, model) :: {:ok, term()} | {:error, term()}
ClaudeEx.set_permission_mode(session, mode) :: {:ok, term()} | {:error, term()}
ClaudeEx.set_max_thinking_tokens(session, n) :: {:ok, term()} | {:error, term()}
ClaudeEx.rewind_files(session, checkpoint_uuid) :: {:ok, term()} | {:error, term()}
ClaudeEx.stop_task(session, task_id) :: {:ok, term()} | {:error, term()}
```

### MCP Server Management

```elixir
ClaudeEx.mcp_server_status(session) :: {:ok, term()} | {:error, term()}
ClaudeEx.set_mcp_servers(session, servers) :: {:ok, term()} | {:error, term()}
ClaudeEx.reconnect_mcp_server(session, name) :: {:ok, term()} | {:error, term()}
ClaudeEx.toggle_mcp_server(session, name, enabled) :: {:ok, term()} | {:error, term()}
```

### Session Info Accessors

```elixir
ClaudeEx.supported_commands(session) :: {:ok, list()} | {:error, term()}
ClaudeEx.supported_models(session) :: {:ok, list()} | {:error, term()}
ClaudeEx.supported_agents(session) :: {:ok, list()} | {:error, term()}
ClaudeEx.account_info(session) :: {:ok, map()} | {:error, term()}
```

### Session Transcript Management

```elixir
ClaudeEx.list_sessions(opts \\ %{}) :: {:ok, [map()]}
ClaudeEx.get_session_messages(session_id) :: {:ok, [map()]} | {:error, atom()}
ClaudeEx.get_session_messages(session_id, opts) :: {:ok, [map()]} | {:error, atom()}
```

### In-Process MCP Servers

```elixir
ClaudeEx.mcp_tool(name, description, schema, handler) :: map()
ClaudeEx.mcp_server(name, tools) :: map()
```

### SDK Hooks

```elixir
ClaudeEx.sdk_hook(event, callback) :: map()
ClaudeEx.sdk_hook(event, callback, matcher) :: map()
```

### Supervisor Integration

```elixir
ClaudeEx.child_spec(opts) :: Supervisor.child_spec()
```

## Session Options

Accepts keyword lists or maps. All options from the Erlang
[agent_wire session_opts()](../../../apps/agent_wire/README.md) are supported:

```elixir
ClaudeEx.start_session(
  cli_path: "/usr/local/bin/claude",
  work_dir: "/my/project",
  permission_mode: "bypassPermissions",
  model: "claude-sonnet-4-20250514",
  system_prompt: "Be concise",
  max_turns: 10,
  resume: true,
  sdk_hooks: [hook1, hook2],
  sdk_mcp_servers: [server1],
  extra_args: %{"--verbose" => nil}   # nil = flag with no value
)
```

## Examples

### In-Process MCP Tool

```elixir
tool = ClaudeEx.mcp_tool(
  "lookup_user",
  "Look up a user by ID",
  %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}},
  fn input ->
    id = Map.get(input, "id", "unknown")
    {:ok, [%{type: :text, text: "User: #{id}"}]}
  end
)
server = ClaudeEx.mcp_server("my-tools", [tool])
{:ok, session} = ClaudeEx.start_session(sdk_mcp_servers: [server])
```

### Lifecycle Hook

```elixir
hook = ClaudeEx.sdk_hook(:pre_tool_use, fn ctx ->
  case Map.get(ctx, :tool_name, "") do
    "Bash" -> {:deny, "Shell access disabled"}
    _ -> :ok
  end
end)
{:ok, session} = ClaudeEx.start_session(sdk_hooks: [hook])
```

### Streaming with Pattern Matching

```elixir
session
|> ClaudeEx.stream!("Analyze this code")
|> Stream.filter(& &1.type in [:text, :tool_use, :result])
|> Enum.each(fn
  %{type: :text, content: c} -> IO.write(c)
  %{type: :tool_use, tool_name: n} -> IO.puts("\nUsing tool: #{n}")
  %{type: :result} = r -> IO.puts("\nCost: $#{Map.get(r, :total_cost_usd, 0)}")
end)
```

### Non-Raising Stream

```elixir
session
|> ClaudeEx.stream("Risky query")
|> Enum.each(fn
  {:ok, msg} -> IO.inspect(msg.type)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end)
```

### Supervisor Integration

```elixir
children = [
  {ClaudeEx, [cli_path: "claude", session_id: "worker-1"]},
  {ClaudeEx, [cli_path: "claude", session_id: "worker-2"]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Intentional Omissions & Workarounds

This wrapper delegates to the Erlang `claude_agent_sdk` facade. For features
not directly wrapped, use the Erlang modules:

```elixir
# Any control protocol command
:claude_agent_session.send_control(session, "method", %{})

# Direct gen_statem calls
:gen_statem.call(session, {:custom_op, args}, 5_000)
```

See the [claude_agent_sdk README](../../../apps/claude_agent_sdk/README.md)
for the full omissions table.
