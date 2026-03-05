# opencode_client

Erlang/OTP adapter for [OpenCode](https://github.com/opencode-ai/opencode) via
HTTP REST + Server-Sent Events (SSE). Uses `gun` for HTTP connections.

This is the only HTTP-based adapter in the SDK. It connects to a running
`opencode serve` instance and provides both REST operations and real-time
streaming via SSE.

## Quick Start

```erlang
%% Start the OpenCode server first: opencode serve

{ok, Session} = opencode_client:start_session(#{
    base_url => <<"http://localhost:4096">>,
    directory => <<"/my/project">>
}),
{ok, Messages} = opencode_client:query(Session, <<"Explain this codebase">>),
opencode_client:stop(Session).
```

## API Reference

### Session Lifecycle

```erlang
opencode_client:start_session(Opts) -> {ok, pid()} | {error, term()}
opencode_client:stop(Session) -> ok
opencode_client:health(Session) -> ready | connecting | initializing | active_query | error
```

### Querying

```erlang
opencode_client:query(Session, Prompt) -> {ok, [Message]} | {error, term()}
opencode_client:query(Session, Prompt, Params) -> {ok, [Message]} | {error, term()}
opencode_client:abort(Session) -> ok | {error, term()}
```

`query/2,3` is blocking with deadline-based timeout (default 120s).
`abort/1` sends `POST /session/:id/abort` to cancel the active query.

### Session Info & Runtime Control

```erlang
opencode_client:session_info(Session) -> {ok, map()} | {error, term()}
opencode_client:set_model(Session, Model) -> {ok, term()} | {error, term()}
```

### SDK Hook Constructors

```erlang
opencode_client:sdk_hook(Event, Callback) -> hook_def()
opencode_client:sdk_hook(Event, Callback, Matcher) -> hook_def()
```

### Supervisor Integration

```erlang
opencode_client:child_spec(Opts) -> supervisor:child_spec()
```

### OpenCode-Specific REST Operations

```erlang
opencode_client:list_sessions(Session) -> {ok, [map()]} | {error, term()}
opencode_client:get_session(Session, Id) -> {ok, map()} | {error, term()}
opencode_client:delete_session(Session, Id) -> {ok, term()} | {error, term()}
opencode_client:send_command(Session, Command, Params) -> {ok, term()} | {error, term()}
opencode_client:server_health(Session) -> {ok, map()} | {error, term()}
```

## Configuration Options

See [agent_wire README](../agent_wire/README.md) for the full `session_opts()` reference.

Key OpenCode options:

```erlang
#{
    base_url => <<"http://localhost:4096">>,  %% OpenCode server URL (required)
    directory => <<"/my/project">>,           %% Workspace directory (required)
    auth => {basic, <<"user">>, <<"pass">>},  %% HTTP Basic Auth (optional)
    model_id => <<"claude-sonnet-4-20250514">>,
    provider_id => <<"anthropic">>,
    agent => <<"coder">>,                      %% OpenCode agent name
    permission_handler => fun/3,               %% Permission callback
    buffer_max => 2097152,                     %% SSE buffer max (2MB)
    sdk_hooks => [Hook1]
}
```

## Permission Handling

OpenCode uses a **fail-closed** permission model — when no `permission_handler`
is set, all permission requests are automatically **denied**. This is the safer
default for an HTTP-based adapter where the server may execute tools with real
system access.

```erlang
%% Approve all permissions (use with caution)
Handler = fun(_PermId, _Metadata, _Opts) -> {allow, #{}} end,
{ok, S} = opencode_client:start_session(#{
    directory => <<"/my/project">>,
    permission_handler => Handler
}).

%% Selective approval
Handler = fun(_PermId, #{<<"tool">> := Tool}, _Opts) ->
    case Tool of
        <<"read">> -> {allow, #{}};
        <<"write">> -> {allow, #{}};
        <<"shell">> -> {deny, <<"Shell access denied">>};
        _ -> {deny, <<"Unknown tool">>}
    end
end.
```

## Wire Protocol

The adapter communicates with `opencode serve` via:

1. **SSE stream** (`GET /event?directory=<dir>`) — Real-time events
2. **REST requests** — Session management, queries, permissions

### SSE Event Mapping

| SSE Event | Condition | agent_wire Type | Key Fields |
|-----------|-----------|----------------|------------|
| `server.connected` | — | `system` | subtype: `connected` |
| `message.part.updated` | text part, delta | `text` | `content` (delta) |
| `message.part.updated` | text part, no delta | `text` | `content` (full) |
| `message.part.updated` | reasoning part | `thinking` | `content` |
| `message.part.updated` | tool, pending/running | `tool_use` | `tool_name`, `tool_input` |
| `message.part.updated` | tool, completed | `tool_result` | `content` |
| `message.part.updated` | tool, error | `error` | `content` |
| `message.part.updated` | step-start | `system` | subtype: `step_start` |
| `message.part.updated` | step-finish | `system` | cost, tokens |
| `session.idle` | during query | `result` | signals complete |
| `session.error` | — | `error` | error details |
| `permission.updated` | — | `control_request` | permission metadata |
| `server.heartbeat` | — | (ignored) | — |

## Examples

### HTTP Basic Auth

When the OpenCode server has `OPENCODE_SERVER_PASSWORD` set:

```erlang
{ok, S} = opencode_client:start_session(#{
    base_url => <<"http://localhost:4096">>,
    directory => <<"/my/project">>,
    auth => {basic, <<"admin">>, <<"secret">>}
}).
```

### Session Management

```erlang
%% List all sessions on the server
{ok, Sessions} = opencode_client:list_sessions(S),

%% Get details for a specific session
{ok, Detail} = opencode_client:get_session(S, <<"session-id-here">>),

%% Delete a session
{ok, _} = opencode_client:delete_session(S, <<"old-session-id">>).
```

### Sending Commands

```erlang
%% Send a slash command to the current session
{ok, _} = opencode_client:send_command(S, <<"/compact">>, #{}).
```

### Server Health Check

```erlang
{ok, Health} = opencode_client:server_health(S).
%% Returns server status, version, etc.
```

### Aborting a Query

```erlang
%% Start a long query in another process
spawn(fun() -> opencode_client:query(S, <<"Refactor entire codebase">>) end),

%% Abort it
timer:sleep(5000),
ok = opencode_client:abort(S).
```

## Cross-Adapter Features

These features are shared across all five BEAM agent adapters via `agent_wire`.

### Telemetry

All state transitions, query spans, and buffer overflows emit
[telemetry](https://hex.pm/packages/telemetry) events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, session, state_change]` | `system_time` | `#{agent => opencode, from_state, to_state}` |
| `[agent_wire, opencode, query, start]` | `system_time` | `#{agent => opencode, prompt}` |
| `[agent_wire, opencode, query, stop]` | `duration` | `#{agent => opencode}` |
| `[agent_wire, opencode, query, exception]` | `system_time` | `#{agent => opencode, reason}` |
| `[agent_wire, buffer, overflow]` | `buffer_size` | `#{max}` |

```erlang
telemetry:attach(<<"my-handler">>,
    [agent_wire, session, state_change],
    fun(_Event, _Measurements, #{agent := opencode, to_state := State}, _Config) ->
        logger:info("OpenCode session now in state: ~p", [State])
    end, #{}).
```

### Content Block Generalization

All adapters normalize messages into `agent_wire:message()` maps. The
`agent_wire_content` module provides adapter-agnostic utilities:

```erlang
Flat = agent_wire_content:normalize_messages(Messages).
Msg = agent_wire_content:block_to_message(Block).
Block = agent_wire_content:message_to_block(Msg).
```

### In-Process MCP Servers

The SDK MCP registry infrastructure is available for OpenCode sessions. Define
tools via `agent_wire_mcp` and pass them as `sdk_mcp_servers`:

```erlang
Tool = agent_wire_mcp:tool(<<"greet">>, <<"Greet">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end),
Server = agent_wire_mcp:server(<<"my-tools">>, [Tool]),
{ok, S} = opencode_client:start_session(#{
    directory => <<"/my/project">>,
    sdk_mcp_servers => [Server]
}).
```

**Note:** The OpenCode server does not dispatch MCP calls to the SDK. The
registry is available for application-level tool dispatch via
`agent_wire_mcp:call_tool_by_name/3`. The `mcp_handler_timeout` option
(default: 30s) controls handler execution timeout.

## Intentional Omissions & Workarounds

The OpenCode server exposes a large REST API surface. This adapter wraps the
most common operations. For anything not covered, use `send_command/3` or
access the gen_statem directly.

### OpenCode Server APIs Not Wrapped

| OpenCode API | Workaround |
|-------------|------------|
| PTY (terminal) | Not applicable for SDK use |
| File operations (read/write/find) | Use agent tool calls instead |
| Config management | Configure via opencode CLI directly |
| Provider auth | Configure via opencode CLI directly |
| Session sharing/fork/diff | Use `get_session/2` + application logic |
| Session summarize | Use `send_command/3` with appropriate command |
| MCP server management | Configure via opencode CLI directly |
| Provider listing | Configure via opencode CLI directly |

### Accessing Unwrapped APIs via send_command

```erlang
%% Send any command the OpenCode server supports
{ok, Result} = opencode_client:send_command(Session, <<"command_name">>, #{
    <<"param1">> => <<"value1">>
}).
```

### Direct gen_statem Access

For operations not covered by the facade:

```erlang
%% The session process handles arbitrary gen_statem:call messages
%% Check opencode_session.erl for supported call patterns
Result = gen_statem:call(Session, {custom_operation, Args}, Timeout).
```

## Internal Architecture

- `opencode_session` — gen_statem managing gun connection, SSE stream, REST requests
- `opencode_protocol` — SSE event normalization (pure functions)
- `opencode_sse` — SSE frame parser (pure functions)
- `opencode_http` — HTTP request/response helpers (pure functions)
- `opencode_client` — Public API facade (this module)

State machine: `connecting -> initializing -> ready <-> active_query -> error`

The session maintains a persistent gun connection with an SSE stream for
real-time events, plus sends REST requests for queries and commands.
