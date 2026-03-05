# copilot_client

Erlang/OTP adapter for [GitHub Copilot](https://github.com/features/copilot) in
CLI server mode. Communicates over a Port using bidirectional JSON-RPC 2.0 with
Content-Length framing (LSP-style).

This adapter uses the richest wire format in the SDK -- standard JSON-RPC 2.0
with `Content-Length: N\r\n\r\n` framing (identical to the Language Server
Protocol), full bidirectional control, server-initiated requests for tool calls,
permissions, hooks, and user input.

## Quick Start

```erlang
{ok, Session} = copilot_client:start_session(#{
    cli_path => "copilot",
    permission_mode => <<"bypassPermissions">>
}),
{ok, Messages} = copilot_client:query(Session, <<"What is 2+2?">>),

lists:foreach(fun
    (#{type := text, content := C}) -> io:format("~s", [C]);
    (#{type := result}) -> io:format("~nDone!~n");
    (_) -> ok
end, Messages),

copilot_client:stop(Session).
```

## API Reference

### Session Lifecycle

```erlang
copilot_client:start_session(Opts) -> {ok, pid()} | {error, term()}
copilot_client:stop(Session) -> ok
copilot_client:health(Session) -> ready | connecting | initializing | active_query | error
```

### Querying

```erlang
copilot_client:query(Session, Prompt) -> {ok, [Message]} | {error, term()}
copilot_client:query(Session, Prompt, Params) -> {ok, [Message]} | {error, term()}
```

`query/2,3` is blocking -- it sends the prompt and collects all response messages
until a `result` or terminal `error` message arrives. Uses deadline-based timeout
(default 120s total, not per-message).

### Session Info & Runtime Control

```erlang
copilot_client:session_info(Session) -> {ok, Map} | {error, term()}
copilot_client:set_model(Session, Model) -> {ok, term()} | {error, term()}
copilot_client:interrupt(Session) -> ok | {error, term()}
copilot_client:abort(Session) -> ok | {error, term()}
```

`session_info/1` returns:
- `copilot_session_id` -- Session ID from the Copilot server
- `model` -- Current model
- `session_created` -- Whether session.create has completed

`interrupt/1` and `abort/1` are aliases -- both cancel the current active query.

### Arbitrary JSON-RPC Commands

```erlang
copilot_client:send_command(Session, Method, Params) -> {ok, term()} | {error, term()}
```

Send any JSON-RPC method the Copilot CLI supports.

### SDK Hook Constructors

```erlang
copilot_client:sdk_hook(Event, Callback) -> hook_def()
copilot_client:sdk_hook(Event, Callback, Matcher) -> hook_def()
```

### Supervisor Integration

```erlang
copilot_client:child_spec(Opts) -> supervisor:child_spec()
```

Uses `session_id` from opts as child ID when available, allowing multiple
sessions under one supervisor.

## Configuration Options

See [agent_wire README](../agent_wire/README.md) for the full `session_opts()` reference.

Key Copilot options:

```erlang
#{
    cli_path => "copilot",                        %% Path to copilot CLI (default: "copilot")
    work_dir => "/my/project",                     %% Working directory
    permission_mode => <<"bypassPermissions">>,   %% or default, acceptEdits, plan
    model => <<"gpt-4o">>,
    system_prompt => <<"Be concise">>,
    max_turns => 10,
    session_id => <<"my-session">>,                %% Resume a session
    sdk_hooks => [Hook1, Hook2],
    sdk_mcp_servers => [Server1],
    tool_handlers => #{<<"my_tool">> => fun/1},    %% In-process tool handlers
    permission_handler => fun/3,                    %% Permission callback
    user_input_handler => fun/2,                    %% User input callback
    protocol_version => 3,                          %% SDK protocol version
    allowed_tools => [<<"Bash">>, <<"Read">>],
    disallowed_tools => [<<"Write">>],
    mcp_servers => #{...},                          %% External MCP servers
    output_format => #{...},                        %% Structured output JSON schema
    thinking => #{type => <<"enabled">>, budget_tokens => 10000},
    effort => <<"high">>
}
```

## Wire Protocol

The Copilot CLI uses **Content-Length framed JSON-RPC 2.0** over stdio:

```
Content-Length: 42\r\n\r\n{"jsonrpc":"2.0","method":"session.event",...}
```

This is the same framing used by the Language Server Protocol (LSP). Unlike the
other adapters which use JSONL, every message has a `Content-Length` header
followed by exactly that many bytes of JSON.

### Session Event Mapping

| Wire Event Type | agent_wire Type | Key Fields |
|----------------|----------------|------------|
| `assistant.message` | `assistant` | `content` |
| `assistant.message_delta` | `text` | `content` (delta) |
| `assistant.reasoning` | `thinking` | `content` |
| `assistant.reasoning_delta` | `thinking` | `content` (delta) |
| `tool.executing` | `tool_use` | `tool_name`, `tool_input`, `tool_use_id` |
| `tool.completed` | `tool_result` | `tool_name`, `content`, `tool_use_id` |
| `tool.errored` | `error` | `tool_name`, `content` |
| `agent.toolCall` | `tool_use` | `tool_name`, `tool_input` |
| `session.idle` | `result` | (signals query complete) |
| `session.error` | `error` | `content` |
| `session.resume` | `system` | subtype: `resume` |
| `permission.request` | `control_request` | permission metadata |
| `permission.resolved` | `control_response` | resolution data |
| `compaction.started` | `system` | subtype: `compaction_started` |
| `compaction.completed` | `system` | subtype: `compaction_completed` |
| `plan.update` | `system` | subtype: `plan_update` |
| `user.message` | `user` | `content` |

### Server-Initiated Requests

The Copilot CLI sends JSON-RPC requests to the SDK (server → client):

| Method | Purpose | SDK Handler |
|--------|---------|-------------|
| `tool.call` | Execute in-process tool | `tool_handlers` opt |
| `permission.request` | Approve/deny permission | `permission_handler` opt |
| `hooks.invoke` | Fire lifecycle hook | `sdk_hooks` opt |
| `user_input.request` | Request user input | `user_input_handler` opt |

All handlers are **fail-closed** -- if no handler is set or the handler crashes,
the SDK responds with a denial/error.

## Examples

### Tool Handlers

Register in-process tools the Copilot CLI can invoke:

```erlang
Tools = #{
    <<"weather">> => fun(#{<<"city">> := City}) ->
        {ok, #{<<"temperature">> => <<"72F">>, <<"city">> => City}}
    end
},
{ok, S} = copilot_client:start_session(#{tool_handlers => Tools}).
```

### Permission Handler

```erlang
Handler = fun(ReqId, Request, _Opts) ->
    case maps:get(<<"kind">>, Request, <<>>) of
        <<"file_write">> -> {allow, #{}};
        <<"shell">> -> {deny, <<"Shell access denied">>};
        _ -> {deny, <<"Not allowed">>}
    end
end,
{ok, S} = copilot_client:start_session(#{permission_handler => Handler}).
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
{ok, Msgs} = copilot_client:query(S, <<"What is 2+2?">>, #{
    output_format => Schema
}).
```

### Thinking / Extended Reasoning

```erlang
{ok, Msgs} = copilot_client:query(S, <<"Solve this complex problem">>, #{
    thinking => #{type => <<"enabled">>, budget_tokens => 10000},
    effort => <<"high">>
}).
%% Messages will include #{type := thinking, content := <<"...">>}
```

### Dynamic Model Switching

```erlang
{ok, _} = copilot_client:set_model(S, <<"gpt-4o">>),
{ok, Msgs1} = copilot_client:query(S, <<"Quick question">>),
{ok, _} = copilot_client:set_model(S, <<"o1-preview">>),
{ok, Msgs2} = copilot_client:query(S, <<"Complex analysis">>).
```

### Hook Example

```erlang
Hook = copilot_client:sdk_hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"No shell access">>};
        _ -> ok
    end
end),
{ok, S} = copilot_client:start_session(#{sdk_hooks => [Hook]}).
```

### Supervisor Integration

```erlang
Children = [
    copilot_client:child_spec(#{
        cli_path => "copilot",
        session_id => <<"worker-1">>
    })
],
{ok, {#{strategy => one_for_one}, Children}}.
```

## Cross-Adapter Features

These features are shared across all five BEAM agent adapters via `agent_wire`.

### Telemetry

All state transitions, query spans, and buffer overflows emit
[telemetry](https://hex.pm/packages/telemetry) events:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, session, state_change]` | `system_time` | `#{agent => copilot, from_state, to_state}` |
| `[agent_wire, copilot, query, start]` | `system_time` | `#{agent => copilot, prompt}` |
| `[agent_wire, copilot, query, stop]` | `duration` | `#{agent => copilot}` |
| `[agent_wire, copilot, query, exception]` | `system_time` | `#{agent => copilot, reason}` |
| `[agent_wire, buffer, overflow]` | `buffer_size` | `#{max}` |

```erlang
telemetry:attach(<<"my-handler">>,
    [agent_wire, session, state_change],
    fun(_Event, _Measurements, #{agent := copilot, to_state := State}, _Config) ->
        logger:info("Copilot session now in state: ~p", [State])
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
copilot_client:start_session(#{permission_default => allow}).
```

### In-Process MCP Servers

The Copilot CLI dispatches tool calls to the SDK. Define tools via the MCP
registry or the `tool_handlers` option:

```erlang
%% Via SDK MCP registry (recommended for cross-adapter portability)
Tool = agent_wire_mcp:tool(<<"greet">>, <<"Greet">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end),
Server = agent_wire_mcp:server(<<"my-tools">>, [Tool]),
{ok, S} = copilot_client:start_session(#{sdk_mcp_servers => [Server]}).
```

The MCP handler timeout is configurable via `mcp_handler_timeout` (default: 30s):

```erlang
copilot_client:start_session(#{mcp_handler_timeout => 60000}).
```

## Intentional Omissions & Workarounds

### Features Available via send_command

```erlang
copilot_client:send_command(Session, <<"some.method">>, #{...}).
```

### Features Available via extra_args

Options that don't have named session_opts fields can be passed as CLI flags:

```erlang
copilot_client:start_session(#{
    extra_args => #{
        <<"--allowedTools">> => <<"Bash,Read,Write">>,
        <<"--verbose">> => null  %% null = flag with no value
    }
}).
```

### Copilot SDK Features Not Directly Mapped

| Copilot SDK Feature | BEAM Workaround |
|---------------------|-----------------|
| `PostToolUseFailure` hook event | Use `post_tool_use` hook -- check for error in context |
| `SubagentStop` / `SubagentStart` | Use `stop` / `session_start` hooks |
| `PreCompact` hook | Not exposed by CLI; context compaction is internal |
| `Notification` hook | Use `post_tool_use` or system message handling |

## Internal Architecture

- `copilot_session` -- gen_statem managing Port lifecycle and JSON-RPC protocol
- `copilot_protocol` -- Event normalization and wire format builders (pure functions)
- `copilot_frame` -- Content-Length frame parser/encoder (pure functions)
- `copilot_client` -- Public API facade (this module)

State machine: `connecting -> initializing -> ready <-> active_query -> error`

The session maintains a persistent Port connection with bidirectional JSON-RPC 2.0
communication. Server-initiated requests (tool calls, permissions, hooks, user
input) are handled inline during active queries.
