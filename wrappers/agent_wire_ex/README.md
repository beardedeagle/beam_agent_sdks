# AgentWire

Idiomatic Elixir wrapper for the `agent_wire` shared foundation library.

All five BEAM Agent SDK adapters (Claude, Codex, Gemini, OpenCode, Copilot)
share this foundation for common types, message normalization, MCP server
support, lifecycle hooks, content block handling, and telemetry.

## Why This Wrapper?

The Erlang `:agent_wire` module works from Elixir, but this wrapper provides:

- **Elixir namespacing**: `AgentWire.MCP`, `AgentWire.Hooks`, `AgentWire.Content`
- **Full typespecs**: visible to Dialyxir, LSP, and ExDoc
- **Idiomatic API**: `nil` instead of `:undefined`, guard clauses, doc examples
- **ExDoc documentation**: browsable on hex.pm

## Modules

| Module | Purpose |
|--------|---------|
| `AgentWire` | Message normalization, request IDs, type parsing |
| `AgentWire.MCP` | In-process MCP server registry and tool dispatch |
| `AgentWire.Hooks` | SDK lifecycle hooks (pre/post tool use, stop, etc.) |
| `AgentWire.Content` | Content block / flat message conversion |
| `AgentWire.Telemetry` | Telemetry event helpers |

## Quick Start

### Defining MCP Tools

```elixir
tool = AgentWire.MCP.tool(
  "lookup_user",
  "Look up a user by ID",
  %{"type" => "object",
    "properties" => %{"id" => %{"type" => "string"}}},
  fn input ->
    id = Map.get(input, "id", "")
    {:ok, [%{type: :text, text: "User: #{id}"}]}
  end
)

server = AgentWire.MCP.server("my-tools", [tool])

# Pass to any adapter
{:ok, session} = ClaudeEx.start_session(sdk_mcp_servers: [server])
```

### Defining Lifecycle Hooks

```elixir
# Block dangerous tool calls
hook = AgentWire.Hooks.hook(:pre_tool_use, fn ctx ->
  case Map.get(ctx, :tool_name, "") do
    "Bash" -> {:deny, "Shell access denied"}
    _ -> :ok
  end
end)

{:ok, session} = ClaudeEx.start_session(sdk_hooks: [hook])
```

### Normalizing Messages

```elixir
# Works identically regardless of which adapter produced the messages
messages
|> AgentWire.Content.normalize_messages()
|> Enum.each(fn
  %{type: :text, content: text} -> IO.write(text)
  %{type: :tool_use, tool_name: name} -> IO.puts("Tool: #{name}")
  %{type: :result} -> IO.puts("Done!")
  _ -> :ok
end)
```

### Telemetry

```elixir
:telemetry.attach("my-handler",
  [:agent_wire, :claude, :query, :stop],
  fn _event, %{duration: d}, _meta, _config ->
    IO.puts("Query took #{System.convert_time_unit(d, :native, :millisecond)}ms")
  end,
  nil
)
```

## Message Types

All adapters normalize messages into `AgentWire.message()`:

| Type | Key Fields |
|------|-----------|
| `:text` | `content` |
| `:assistant` | `content_blocks` |
| `:tool_use` | `tool_name`, `tool_input` |
| `:tool_result` | `tool_name`, `content` |
| `:result` | `content`, `duration_ms`, `total_cost_usd` |
| `:error` | `content` |
| `:thinking` | `content` |
| `:system` | `content`, `subtype`, `system_info` |

## Requirements

- Elixir ~> 1.17
- Erlang/OTP 27+
- `telemetry` ~> 1.3 (transitive via `agent_wire`)

## Per-Adapter Wrappers

This library is the shared foundation. For adapter-specific wrappers, see:

- [ClaudeEx](../../wrappers/claude_ex/README.md)
- [CodexEx](../../wrappers/codex_ex/README.md)
- [GeminiEx](../../wrappers/gemini_ex/README.md)
- [OpencodeEx](../../wrappers/opencode_ex/README.md)
- [CopilotEx](../../wrappers/copilot_ex/README.md)
