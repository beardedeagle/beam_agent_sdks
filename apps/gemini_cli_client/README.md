# gemini_cli_client

Erlang/OTP adapter for the [Gemini CLI](https://github.com/google-gemini/gemini-cli)
agent. Communicates over Port using JSONL (one-shot per query).

The simplest of the five adapters — no persistent connection, no bidirectional
control protocol. Each query spawns a new port process. Session IDs are captured
from init events and automatically reused via `--resume` for subsequent queries.

## Quick Start

```erlang
{ok, Session} = gemini_cli_client:start_session(#{
    cli_path => "gemini",
    approval_mode => <<"yolo">>
}),
{ok, Messages} = gemini_cli_client:query(Session, <<"What is 2+2?">>),
gemini_cli_client:stop(Session).
```

## API Reference

### Session Lifecycle

```erlang
gemini_cli_client:start_session(Opts) -> {ok, pid()} | {error, term()}
gemini_cli_client:stop(Session) -> ok
gemini_cli_client:health(Session) -> ready | connecting | initializing | active_query | error
```

### Querying

```erlang
gemini_cli_client:query(Session, Prompt) -> {ok, [Message]} | {error, term()}
gemini_cli_client:query(Session, Prompt, Params) -> {ok, [Message]} | {error, term()}
```

Blocking with deadline-based timeout (default 120s).

### Session Info & Runtime Control

```erlang
gemini_cli_client:session_info(Session) -> {ok, map()} | {error, term()}
gemini_cli_client:set_model(Session, Model) -> {ok, term()} | {error, term()}
gemini_cli_client:interrupt(Session) -> ok | {error, term()}
```

`session_info/1` returns:
- `session_id` — Captured from init event (used for `--resume`)
- `model` — Current model
- `approval_mode` — Current approval mode

`interrupt/1` closes the active port (kills the CLI process).

### SDK Hook Constructors

```erlang
gemini_cli_client:sdk_hook(Event, Callback) -> hook_def()
gemini_cli_client:sdk_hook(Event, Callback, Matcher) -> hook_def()
```

### Supervisor Integration

```erlang
gemini_cli_client:child_spec(Opts) -> supervisor:child_spec()
```

## Configuration Options

See [agent_wire README](../agent_wire/README.md) for the full `session_opts()` reference.

Key Gemini CLI options:

```erlang
#{
    cli_path => "gemini",                %% Path to gemini CLI
    work_dir => "/my/project",
    model => <<"gemini-2.5-pro">>,
    approval_mode => <<"yolo">>,         %% yolo, default, auto_edit, plan
    settings_file => "/path/to/settings.json",
    env => [{"GEMINI_API_KEY", "..."}],
    sdk_hooks => [Hook1]
}
```

## Wire Protocol

The Gemini CLI outputs streaming JSON events on stdout when invoked with
`--output-format stream-json`. Event types:

| Wire Event | agent_wire Type | Key Fields |
|-----------|----------------|------------|
| `init` | `system` (subtype: `init`) | `session_id`, `model` |
| `message` (role=user) | `user` | `content` |
| `message` (role=assistant, delta) | `text` | `content` (text delta) |
| `tool_use` | `tool_use` | `tool_name`, `tool_input`, `tool_use_id` |
| `tool_result` (success) | `tool_result` | `content`, `tool_use_id` |
| `tool_result` (error) | `error` | error type + message |
| `error` (warning) | `system` (subtype: `warning`) | `content` |
| `error` (error) | `error` | `content` |
| `result` (success) | `result` | `stats` (tokens, duration, tool_calls) |
| `result` (error) | `error` | error type + message |

Exit codes: 0=success, 41=auth error, 42=input error, 52=config error, 130=cancelled.

## Examples

### Session Resume

The adapter automatically captures `session_id` from init events. Subsequent
queries within the same session process reuse it via `--resume`:

```erlang
{ok, S} = gemini_cli_client:start_session(#{cli_path => "gemini"}),
{ok, _} = gemini_cli_client:query(S, <<"Define a helper function">>),
%% Second query automatically resumes the session
{ok, _} = gemini_cli_client:query(S, <<"Now add error handling to it">>).
```

### Model Override Per Query

```erlang
{ok, _} = gemini_cli_client:query(S, <<"Quick question">>, #{
    model => <<"gemini-2.5-flash">>
}).
```

### Hook Example

```erlang
Hook = gemini_cli_client:sdk_hook(post_tool_use, fun(Ctx) ->
    logger:info("Gemini used tool: ~s", [maps:get(tool_name, Ctx, <<>>)]),
    ok
end),
{ok, S} = gemini_cli_client:start_session(#{
    cli_path => "gemini",
    sdk_hooks => [Hook]
}).
```

## Cross-Adapter Features

These features are shared across all five BEAM agent adapters via `agent_wire`.

### Telemetry

All state transitions, query spans, and buffer overflows emit
[telemetry](https://hex.pm/packages/telemetry) events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, session, state_change]` | `system_time` | `#{agent => gemini, from_state, to_state}` |
| `[agent_wire, gemini, query, start]` | `system_time` | `#{agent => gemini, prompt}` |
| `[agent_wire, gemini, query, stop]` | `duration` | `#{agent => gemini}` |
| `[agent_wire, gemini, query, exception]` | `system_time` | `#{agent => gemini, reason}` |
| `[agent_wire, buffer, overflow]` | `buffer_size` | `#{max}` |

```erlang
telemetry:attach(<<"my-handler">>,
    [agent_wire, session, state_change],
    fun(_Event, _Measurements, #{agent := gemini, to_state := State}, _Config) ->
        logger:info("Gemini session now in state: ~p", [State])
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

### Permission Defaults

All adapters default to **fail-closed** — when no `permission_handler` is set,
permission requests are denied. Override with `permission_default`:

```erlang
gemini_cli_client:start_session(#{permission_default => allow}).
```

### In-Process MCP Servers

The SDK MCP registry infrastructure is available for Gemini sessions. Define
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
{ok, S} = gemini_cli_client:start_session(#{sdk_mcp_servers => [Server]}).
```

**Note:** The Gemini CLI itself does not dispatch MCP calls to the SDK. The
registry is available for application-level tool dispatch via
`agent_wire_mcp:call_tool_by_name/3`. The `mcp_handler_timeout` option
(default: 30s) controls handler execution timeout.

## Intentional Omissions & Workarounds

### No Bidirectional Control Protocol

The Gemini CLI is unidirectional (stdout only). There is no `send_control/3`
equivalent. Features like runtime MCP server management or dynamic permission
changes are not available.

### No CLI-Dispatched MCP Servers

The Gemini CLI does not dispatch MCP tool calls to SDK-registered servers.
The `sdk_mcp_servers` option registers tools in the SDK MCP registry for
application-level dispatch via `agent_wire_mcp:call_tool_by_name/3`, but the
CLI itself will never invoke them. See the "In-Process MCP Servers" section
above for the registry API.

### Features Available via extra_args

Any CLI flags not covered by named options:

```erlang
gemini_cli_client:start_session(#{
    extra_args => #{
        <<"--sandbox">> => <<"true">>,
        <<"--verbose">> => null
    }
}).
```

### Gemini CLI Features Not Directly Mapped

| Gemini Feature | BEAM Status |
|---------------|-------------|
| Interactive mode | Not supported (SDK uses `--prompt` mode) |
| Sandbox configuration | Pass via `extra_args` |
| Custom extensions | Pass via `extra_args` |

## Internal Architecture

- `gemini_cli_session` — gen_statem managing port lifecycle (one port per query)
- `gemini_cli_protocol` — Event normalization (pure functions)
- `gemini_cli_client` — Public API facade (this module)

State machine: `idle <-> active_query -> error`

Between queries, no port exists. The session process holds captured `session_id`
and configuration for the next query.
