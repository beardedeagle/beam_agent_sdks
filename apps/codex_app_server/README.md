# codex_app_server

Erlang/OTP adapter for the [Codex CLI](https://github.com/openai/codex) agent.
Supports two transports:

- **App-server** (`codex_session`) -- Full bidirectional JSON-RPC over Port.
  Persistent connection, thread management, control protocol.
- **One-shot** (`codex_exec`) -- Simpler JSONL over Port. No persistent
  connection. Good for stateless queries.

## Quick Start

```erlang
%% App-server transport (full features)
{ok, Session} = codex_app_server:start_session(#{
    cli_path => "codex",
    approval_policy => <<"full-auto">>
}),
{ok, Messages} = codex_app_server:query(Session, <<"What is 2+2?">>),
codex_app_server:stop(Session).

%% One-shot transport (simpler)
{ok, OneShot} = codex_app_server:start_exec(#{cli_path => "codex"}),
{ok, Messages} = codex_app_server:query(OneShot, <<"Explain closures">>),
codex_app_server:stop(OneShot).
```

## API Reference

### Session Lifecycle

```erlang
codex_app_server:start_session(Opts) -> {ok, pid()} | {error, term()}  %% app-server
codex_app_server:start_exec(Opts) -> {ok, pid()} | {error, term()}     %% one-shot
codex_app_server:stop(Session) -> ok
codex_app_server:health(Session) -> ready | connecting | initializing
                                  | active_turn | active_query | error
```

### Querying

```erlang
codex_app_server:query(Session, Prompt) -> {ok, [Message]} | {error, term()}
codex_app_server:query(Session, Prompt, Params) -> {ok, [Message]} | {error, term()}
```

Works with both transports. Blocking with deadline-based timeout (default 120s).

### Thread Management (App-server Only)

```erlang
codex_app_server:thread_start(Session, Opts) -> {ok, map()} | {error, term()}
codex_app_server:thread_resume(Session, ThreadId) -> {ok, map()} | {error, term()}
codex_app_server:thread_list(Session) -> {ok, [map()]} | {error, term()}
```

Returns `{error, not_supported}` for one-shot sessions.

### Session Info and Runtime Control

```erlang
codex_app_server:session_info(Session) -> {ok, map()} | {error, term()}
codex_app_server:set_model(Session, Model) -> {ok, term()} | {error, term()}
codex_app_server:interrupt(Session) -> ok | {error, term()}
```

### SDK Hook Constructors

```erlang
codex_app_server:sdk_hook(Event, Callback) -> hook_def()
codex_app_server:sdk_hook(Event, Callback, Matcher) -> hook_def()
```

### Supervisor Integration

```erlang
codex_app_server:child_spec(Opts) -> supervisor:child_spec()        %% app-server
codex_app_server:exec_child_spec(Opts) -> supervisor:child_spec()   %% one-shot
```

## Configuration Options

See [agent_wire README](../agent_wire/README.md) for the full `session_opts()` reference.

Key Codex options:

```erlang
#{
    cli_path => "codex",                            %% Path to codex CLI
    work_dir => "/my/project",
    transport => app_server,                         %% app_server | exec
    model => <<"codex-mini-latest">>,
    approval_policy => <<"full-auto">>,              %% auto-edit, full-auto, manual
    sandbox_mode => <<"docker">>,                    %% docker, none
    base_instructions => <<"Always explain your reasoning">>,
    developer_instructions => <<"Use functional patterns">>,
    thread_id => <<"thread_abc123">>,                %% Resume a thread
    ephemeral => true,                               %% No persistence
    sdk_hooks => [Hook1]
}
```

## Transport Comparison

| Feature | App-server | One-shot |
|---------|-----------|----------|
| Thread management | Yes | No |
| Bidirectional control | Yes | No |
| Persistent connection | Yes | No (new port per query) |
| interrupt/1 | Sends control message | Kills port |
| send_control | Full support | Returns `{error, not_supported}` |

## Examples

### Thread Management

```erlang
{ok, S} = codex_app_server:start_session(#{cli_path => "codex"}),

%% Start a new thread
{ok, #{<<"threadId">> := TID}} = codex_app_server:thread_start(S, #{}),

%% Query in that thread
{ok, Msgs1} = codex_app_server:query(S, <<"Define a Fibonacci function">>),

%% List threads
{ok, Threads} = codex_app_server:thread_list(S),

%% Resume a different thread
{ok, _} = codex_app_server:thread_resume(S, SomeOtherThreadId).
```

### Approval Handler

```erlang
Handler = fun(ToolName, ToolInput, _Options) ->
    case ToolName of
        <<"shell">> -> deny;
        _ -> approve
    end
end,
{ok, S} = codex_app_server:start_session(#{
    cli_path => "codex",
    approval_handler => Handler
}).
```

## Cross-Adapter Features

These features are shared across all five BEAM agent adapters via `agent_wire`.

### Telemetry

All state transitions, query spans, and buffer overflows emit
[telemetry](https://hex.pm/packages/telemetry) events. Both transports are
instrumented:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, session, state_change]` | `system_time` | `#{agent => codex \| codex_exec, from_state, to_state}` |
| `[agent_wire, codex, query, start]` | `system_time` | `#{agent => codex, prompt}` |
| `[agent_wire, codex, query, stop]` | `duration` | `#{agent => codex}` |
| `[agent_wire, codex, query, exception]` | `system_time` | `#{agent => codex, reason}` |
| `[agent_wire, codex_exec, query, start]` | `system_time` | `#{agent => codex_exec, prompt}` |
| `[agent_wire, codex_exec, query, stop]` | `duration` | `#{agent => codex_exec}` |
| `[agent_wire, codex_exec, query, exception]` | `system_time` | `#{agent => codex_exec, reason}` |
| `[agent_wire, buffer, overflow]` | `buffer_size` | `#{max}` |

```erlang
telemetry:attach(<<"my-handler">>,
    [agent_wire, session, state_change],
    fun(_Event, _Measurements, #{agent := Agent, to_state := State}, _Config) ->
        logger:info("~p session now in state: ~p", [Agent, State])
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

All adapters default to **fail-closed** — when no `permission_handler` or
`approval_handler` is set, permission requests are denied. Override with
`permission_default`:

```erlang
codex_app_server:start_session(#{permission_default => allow}).
```

### In-Process MCP Servers

Define custom tools as Erlang functions via the SDK MCP registry:

```erlang
Tool = agent_wire_mcp:tool(<<"greet">>, <<"Greet">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Name = maps:get(<<"name">>, Input, <<"world">>),
        {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
    end),
Server = agent_wire_mcp:server(<<"my-tools">>, [Tool]),
{ok, S} = codex_app_server:start_session(#{sdk_mcp_servers => [Server]}).
```

The MCP handler timeout is configurable via `mcp_handler_timeout` (default: 30s):

```erlang
codex_app_server:start_session(#{mcp_handler_timeout => 60000}).
```

## Intentional Omissions and Workarounds

### Features Available via send_control (App-server Only)

The app-server transport supports arbitrary control messages. Any Codex protocol
command not wrapped in a convenience function can be sent directly:

```erlang
%% Via the session module directly
codex_session:send_control(Session, <<"some/method">>, #{...}).
```

### Features Available via extra_args

```erlang
codex_app_server:start_session(#{
    extra_args => #{
        <<"--notify">> => null,
        <<"--full-stdout">> => null
    }
}).
```

### Codex Protocol Features Not Directly Mapped

| Codex Feature | BEAM Workaround |
|--------------|-----------------|
| `NewConversationParams` extra fields | Pass via `extra_args` or `send_control` |
| `InitializeParams` extensions | Available in `session_info/1` init_response |

## Internal Architecture

- `codex_session` -- gen_statem for app-server transport (Port + JSON-RPC)
- `codex_exec` -- gen_statem for one-shot transport (Port + JSONL per query)
- `codex_protocol` -- Codex wire protocol helpers (pure functions)
- `codex_app_server` -- Public API facade (this module)

App-server states: `connecting -> initializing -> ready <-> active_turn -> error`
One-shot states: `idle <-> active_query -> error`
