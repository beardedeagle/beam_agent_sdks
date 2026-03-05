# CopilotEx

Elixir wrapper for the GitHub Copilot agent SDK. Provides idiomatic Elixir access
to `copilot_session` (Erlang/OTP gen_statem) with lazy streaming via
`Stream.resource/3`.

Copilot uses the richest wire format in the SDK -- bidirectional JSON-RPC 2.0 with
Content-Length framing, supporting in-process tool handlers, permissions, hooks,
and user input callbacks.

## Installation

Add to your `mix.exs`:

```elixir
defp deps do
  [{:copilot_ex, path: "wrappers/copilot_ex"}]
end
```

## Quick Start

```elixir
{:ok, session} = CopilotEx.start_session(cli_path: "copilot")

# Blocking query
{:ok, messages} = CopilotEx.query(session, "What is 2+2?")

# Streaming query (lazy)
session
|> CopilotEx.stream!("Explain OTP supervision trees")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :result -> IO.puts("\n--- Done ---")
    _ -> :ok
  end
end)

CopilotEx.stop(session)
```

## API Reference

### Session Lifecycle

```elixir
CopilotEx.start_session(opts) :: {:ok, pid()} | {:error, term()}
CopilotEx.stop(session) :: :ok
CopilotEx.health(session) :: atom()
```

### Querying

```elixir
CopilotEx.query(session, prompt, params \\ %{}) :: {:ok, [map()]} | {:error, term()}
```

Blocking. Collects all messages until result/error. Default timeout: 120s.

### Streaming

```elixir
# Raises on errors
CopilotEx.stream!(session, prompt, params \\ %{}) :: Enumerable.t()

# Returns {:ok, msg} / {:error, reason} tuples
CopilotEx.stream(session, prompt, params \\ %{}) :: Enumerable.t()
```

Both return lazy `Stream.resource/3` enumerables. `stream!/3` raises on errors;
`stream/3` wraps each element in ok/error tuples.

### Session Info & Runtime Control

```elixir
CopilotEx.session_info(session) :: {:ok, map()} | {:error, term()}
CopilotEx.set_model(session, model) :: {:ok, term()} | {:error, term()}
CopilotEx.interrupt(session) :: :ok | {:error, term()}
CopilotEx.abort(session) :: :ok | {:error, term()}
```

### Arbitrary JSON-RPC Commands

```elixir
CopilotEx.send_command(session, method, params \\ %{}) :: {:ok, term()} | {:error, term()}
```

### SDK Hooks

```elixir
CopilotEx.sdk_hook(event, callback) :: map()
CopilotEx.sdk_hook(event, callback, matcher) :: map()
```

### Supervisor Integration

```elixir
CopilotEx.child_spec(opts) :: Supervisor.child_spec()
```

## Session Options

Accepts keyword lists or maps. All options from the Erlang
[agent_wire session_opts()](../../apps/agent_wire/README.md) are supported:

```elixir
CopilotEx.start_session(
  cli_path: "copilot",
  work_dir: "/my/project",
  permission_mode: "bypassPermissions",
  model: "gpt-4o",
  system_prompt: "Be concise",
  max_turns: 10,
  session_id: "my-session",
  sdk_hooks: [hook1, hook2],
  sdk_mcp_servers: [server1],
  tool_handlers: %{"weather" => &my_weather_handler/1},
  permission_handler: &my_perm_handler/3,
  user_input_handler: &my_input_handler/2,
  output_format: %{"type" => "object", ...},
  thinking: %{type: "enabled", budget_tokens: 10000},
  effort: "high"
)
```

## Examples

### Tool Handlers

```elixir
tools = %{
  "weather" => fn %{"city" => city} ->
    {:ok, %{"temperature" => "72F", "city" => city}}
  end
}
{:ok, session} = CopilotEx.start_session(
  cli_path: "copilot",
  tool_handlers: tools
)
```

### Permission Handler

```elixir
handler = fn _req_id, request, _opts ->
  case Map.get(request, "kind") do
    "file_write" -> {:allow, %{}}
    "shell" -> {:deny, "Shell access denied"}
    _ -> {:deny, "Not allowed"}
  end
end
{:ok, session} = CopilotEx.start_session(
  cli_path: "copilot",
  permission_handler: handler
)
```

### Lifecycle Hook

```elixir
hook = CopilotEx.sdk_hook(:pre_tool_use, fn ctx ->
  case Map.get(ctx, :tool_name, "") do
    "Bash" -> {:deny, "Shell access disabled"}
    _ -> :ok
  end
end)
{:ok, session} = CopilotEx.start_session(sdk_hooks: [hook])
```

### Streaming with Pattern Matching

```elixir
session
|> CopilotEx.stream!("Analyze this code")
|> Stream.filter(& &1.type in [:text, :tool_use, :result])
|> Enum.each(fn
  %{type: :text, content: c} -> IO.write(c)
  %{type: :tool_use, tool_name: n} -> IO.puts("\nUsing tool: #{n}")
  %{type: :result} -> IO.puts("\n--- Complete ---")
end)
```

### Non-Raising Stream

```elixir
session
|> CopilotEx.stream("Risky query")
|> Enum.each(fn
  {:ok, msg} -> IO.inspect(msg.type)
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end)
```

### Structured Output

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "answer" => %{"type" => "number"},
    "explanation" => %{"type" => "string"}
  }
}
{:ok, msgs} = CopilotEx.query(session, "What is 2+2?", %{
  output_format: schema
})
```

### Supervisor Integration

```elixir
children = [
  {CopilotEx, [cli_path: "copilot", session_id: "worker-1"]},
  {CopilotEx, [cli_path: "copilot", session_id: "worker-2"]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Intentional Omissions & Workarounds

This wrapper delegates to the Erlang `copilot_client` facade. For features
not directly wrapped, use the Erlang modules:

```elixir
# Any JSON-RPC command
:copilot_session.send_control(session, "method", %{})

# Direct gen_statem calls
:gen_statem.call(session, {:custom_op, args}, 5_000)
```

See the [copilot_client README](../../apps/copilot_client/README.md)
for the full omissions table.

## Shared Foundation

MCP servers, lifecycle hooks, content blocks, and telemetry are provided by
[AgentWire](../agent_wire_ex/README.md) — the shared Elixir foundation used
by all five adapter wrappers.
