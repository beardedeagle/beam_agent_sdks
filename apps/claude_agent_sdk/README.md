# claude_agent_sdk

Erlang/OTP adapter for the [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
agent. Communicates with the Claude CLI over a Port using JSONL + a bidirectional
control protocol.

This is the most feature-rich adapter — it supports all Claude Code SDK features
including in-process MCP servers, lifecycle hooks, permissions, structured output,
thinking, file checkpointing, session management, and more.

## Quick Start

```erlang
%% Start a session
{ok, Session} = claude_agent_sdk:start_session(#{
    cli_path => "/usr/local/bin/claude",
    permission_mode => <<"bypassPermissions">>
}),

%% Blocking query
{ok, Messages} = claude_agent_sdk:query(Session, <<"What is 2+2?">>),

%% Process messages
lists:foreach(fun
    (#{type := text, content := C}) -> io:format("~s", [C]);
    (#{type := result, content := C}) -> io:format("~nResult: ~s~n", [C]);
    (_) -> ok
end, Messages),

%% Stop
claude_agent_sdk:stop(Session).
```

## API Reference

### Session Lifecycle

```erlang
claude_agent_sdk:start_session(Opts) -> {ok, pid()} | {error, term()}
claude_agent_sdk:stop(Session) -> ok
claude_agent_sdk:health(Session) -> ready | connecting | initializing | active_query | error
```

### Querying

```erlang
claude_agent_sdk:query(Session, Prompt) -> {ok, [Message]} | {error, term()}
claude_agent_sdk:query(Session, Prompt, Params) -> {ok, [Message]} | {error, term()}
```

`query/2,3` is blocking — it sends the prompt and collects all response messages
until a `result` or `error` message arrives. Uses deadline-based timeout (default
120s total, not per-message).

### Session Info & Runtime Control

```erlang
claude_agent_sdk:session_info(Session) -> {ok, Map} | {error, term()}
claude_agent_sdk:set_model(Session, Model) -> {ok, term()} | {error, term()}
claude_agent_sdk:set_permission_mode(Session, Mode) -> {ok, term()} | {error, term()}
claude_agent_sdk:set_max_thinking_tokens(Session, N) -> {ok, term()} | {error, term()}
claude_agent_sdk:rewind_files(Session, CheckpointUuid) -> {ok, term()} | {error, term()}
claude_agent_sdk:stop_task(Session, TaskId) -> {ok, term()} | {error, term()}
```

`session_info/1` returns a map with:
- `session_id` — Current session ID
- `system_info` — Parsed init metadata (tools, model, MCP servers, commands, etc.)
- `init_response` — Raw initialize control_response

### MCP Server Management

```erlang
claude_agent_sdk:mcp_server_status(Session) -> {ok, term()} | {error, term()}
claude_agent_sdk:set_mcp_servers(Session, Servers) -> {ok, term()} | {error, term()}
claude_agent_sdk:reconnect_mcp_server(Session, Name) -> {ok, term()} | {error, term()}
claude_agent_sdk:toggle_mcp_server(Session, Name, Enabled) -> {ok, term()} | {error, term()}
```

### Session Info Accessors

Convenience functions that extract fields from the init response:

```erlang
claude_agent_sdk:supported_commands(Session) -> {ok, list()} | {error, term()}
claude_agent_sdk:supported_models(Session) -> {ok, list()} | {error, term()}
claude_agent_sdk:supported_agents(Session) -> {ok, list()} | {error, term()}
claude_agent_sdk:account_info(Session) -> {ok, map()} | {error, term()}
```

### Session Transcript Management

Read past session transcripts from Claude's config directory:

```erlang
claude_agent_sdk:list_sessions() -> {ok, [SessionSummary]}
claude_agent_sdk:list_sessions(Opts) -> {ok, [SessionSummary]}
claude_agent_sdk:get_session_messages(SessionId) -> {ok, [map()]} | {error, atom()}
claude_agent_sdk:get_session_messages(SessionId, Opts) -> {ok, [map()]} | {error, atom()}
```

Options for `list_sessions/1`: `cwd`, `limit`, `config_dir`.

### SDK MCP Server Constructors

```erlang
claude_agent_sdk:mcp_tool(Name, Desc, Schema, Handler) -> tool_def()
claude_agent_sdk:mcp_server(Name, Tools) -> sdk_mcp_server()
```

### SDK Hook Constructors

```erlang
claude_agent_sdk:sdk_hook(Event, Callback) -> hook_def()
claude_agent_sdk:sdk_hook(Event, Callback, Matcher) -> hook_def()
```

### Supervisor Integration

```erlang
claude_agent_sdk:child_spec(Opts) -> supervisor:child_spec()
```

Uses `session_id` from opts as child ID when available, allowing multiple
sessions under one supervisor.

## Configuration Options

See [agent_wire README](../agent_wire/README.md) for the full `session_opts()` reference.

Key Claude Code options:

```erlang
#{
    cli_path => "/usr/local/bin/claude",       %% Path to claude CLI
    work_dir => "/my/project",                  %% Working directory
    permission_mode => <<"bypassPermissions">>, %% or default, acceptEdits, plan
    model => <<"claude-sonnet-4-20250514">>,
    system_prompt => <<"Be concise">>,          %% or #{type => preset, preset => <<"claude_code">>}
    max_turns => 10,
    resume => true,                             %% Resume previous session
    session_id => <<"my-session">>,
    sdk_hooks => [Hook1, Hook2],
    sdk_mcp_servers => [Server1],
    extra_args => #{<<"--verbose">> => null}     %% Extra CLI flags
}
```

## Examples

### Permission Handler

```erlang
Handler = fun(ToolName, ToolInput, _Options) ->
    case ToolName of
        <<"Bash">> ->
            Cmd = maps:get(<<"command">>, ToolInput, <<>>),
            case binary:match(Cmd, <<"rm ">>) of
                nomatch -> {allow, ToolInput};
                _ -> {deny, <<"Destructive commands not allowed">>}
            end;
        _ -> {allow, ToolInput}
    end
end,
{ok, S} = claude_agent_sdk:start_session(#{permission_handler => Handler}).
```

### Structured Output

```erlang
Schema = #{
    <<"type">> => <<"object">>,
    <<"properties">> => #{
        <<"answer">> => #{<<"type">> => <<"number">>},
        <<"explanation">> => #{<<"type">> => <<"string">>}
    }
},
{ok, Msgs} = claude_agent_sdk:query(S, <<"What is 2+2?">>, #{
    output_format => Schema
}).
%% Result message will have structured_output field
```

### Thinking / Extended Reasoning

```erlang
{ok, Msgs} = claude_agent_sdk:query(S, <<"Solve this complex problem">>, #{
    thinking => #{type => <<"enabled">>, budget_tokens => 10000},
    effort => <<"high">>
}).
%% Messages will include #{type := thinking, content := <<"...">>} messages
```

### Dynamic Model Switching

```erlang
{ok, _} = claude_agent_sdk:set_model(Session, <<"claude-sonnet-4-20250514">>),
{ok, Msgs1} = claude_agent_sdk:query(Session, <<"Quick question">>),
{ok, _} = claude_agent_sdk:set_model(Session, <<"claude-opus-4-20250514">>),
{ok, Msgs2} = claude_agent_sdk:query(Session, <<"Complex analysis">>).
```

## Cross-Adapter Features

These features are shared across all five BEAM agent adapters via `agent_wire`.

### Telemetry

All state transitions, query spans, and buffer overflows emit
[telemetry](https://hex.pm/packages/telemetry) events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, session, state_change]` | `system_time` | `#{agent => claude, from_state, to_state}` |
| `[agent_wire, claude, query, start]` | `system_time` | `#{agent => claude, prompt}` |
| `[agent_wire, claude, query, stop]` | `duration` | `#{agent => claude}` |
| `[agent_wire, claude, query, exception]` | `system_time` | `#{agent => claude, reason}` |
| `[agent_wire, buffer, overflow]` | `buffer_size` | `#{max}` |

```erlang
%% Attach a handler at application startup
telemetry:attach(<<"my-handler">>,
    [agent_wire, session, state_change],
    fun(_Event, _Measurements, #{agent := claude, to_state := State}, _Config) ->
        logger:info("Claude session now in state: ~p", [State])
    end, #{}).
```

### Content Block Generalization

All adapters normalize messages into `agent_wire:message()` maps. The
`agent_wire_content` module provides adapter-agnostic utilities:

```erlang
%% Flatten assistant messages with nested content_blocks into individual messages
Flat = agent_wire_content:normalize_messages(Messages).

%% Convert a content block to a standalone message (and vice versa)
Msg = agent_wire_content:block_to_message(Block).
Block = agent_wire_content:message_to_block(Msg).
```

### Permission Defaults

All adapters default to **fail-closed** — when no `permission_handler` is set,
permission requests are denied. Override with `permission_default`:

```erlang
%% Auto-approve (use with caution)
claude_agent_sdk:start_session(#{permission_default => allow}).

%% Explicit deny (the default)
claude_agent_sdk:start_session(#{permission_default => deny}).
```

### In-Process MCP Servers

Define custom tools as Erlang functions that the agent can call in-process:

```erlang
Tool = claude_agent_sdk:mcp_tool(<<"greet">>, <<"Greet a user">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end),
Server = claude_agent_sdk:mcp_server(<<"my-tools">>, [Tool]),
{ok, S} = claude_agent_sdk:start_session(#{sdk_mcp_servers => [Server]}).
```

The MCP handler timeout is configurable via `mcp_handler_timeout` (default: 30s):

```erlang
claude_agent_sdk:start_session(#{mcp_handler_timeout => 60000}).
```

## Intentional Omissions & Workarounds

The following Python/TypeScript SDK features are accessible but not wrapped in
named convenience functions. Use `claude_agent_session:send_control/3` for any
protocol command not listed in the API reference above.

### Features Available via send_control

```erlang
%% Any control method the CLI supports:
claude_agent_session:send_control(Session, <<"some/method">>, #{...}).
```

### Features Available via extra_args

Options that don't have named session_opts fields can be passed as CLI flags:

```erlang
claude_agent_sdk:start_session(#{
    extra_args => #{
        <<"--allowedTools">> => <<"Bash,Read,Write">>,
        <<"--verbose">> => null  %% null = flag with no value
    }
}).
```

### Python SDK Features Not Directly Mapped

| Python SDK Feature | BEAM Workaround |
|-------------------|-----------------|
| `PostToolUseFailure` hook event | Use `post_tool_use` hook — check for error in context |
| `SubagentStop` / `SubagentStart` | Use `stop` / `session_start` hooks |
| `PreCompact` hook | Not exposed by CLI; context compaction is internal |
| `Notification` hook | Use `post_tool_use` or system message handling |
| `PermissionRequest` hook | Use `permission_handler` session opt instead |
| `AgentDefinition` | Pass via `agents` session opt or `extra_args` |
| `SandboxSettings` | Pass via `sandbox` session opt |

## Internal Architecture

- `claude_agent_session` — gen_statem managing the Port lifecycle and control protocol
- `claude_agent_sdk` — Public API facade (this module)
- `claude_session_store` — Session transcript reader

State machine: `connecting -> initializing -> ready <-> active_query -> error`
