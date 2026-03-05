# agent_wire

Shared foundation library for the BEAM Agent SDKs. Provides unified types,
JSONL parsing, message queuing, lifecycle hooks, in-process MCP servers,
content block parsing, telemetry, and transport behaviour — used by all five
adapter apps.

**This library has no processes.** It is pure functions and type definitions.
Adapter apps (`claude_agent_sdk`, `codex_app_server`, etc.) build their
gen_statem sessions on top of these primitives.

## Modules

| Module | Purpose |
|--------|---------|
| `agent_wire` | Unified message types, normalization, query/session opts |
| `agent_wire_jsonl` | JSONL frame parsing (newline-delimited JSON) |
| `agent_wire_jsonrpc` | JSON-RPC 2.0 encoding/decoding (Codex protocol) |
| `agent_wire_content` | Content block parsing (text, tool_use, tool_result, thinking, image) |
| `agent_wire_queue` | Bounded message queue with backpressure |
| `agent_wire_hooks` | SDK lifecycle hook registry and dispatch |
| `agent_wire_mcp` | In-process MCP server/tool definitions and dispatch |
| `agent_wire_telemetry` | Telemetry event emission helpers |
| `agent_wire_transport` | Transport behaviour (callback specification) |
| `agent_wire_behaviour` | Consumer API behaviour (shared gen_statem interface) |
| `agent_wire_todo` | Todo/task list management for structured output |

## Message Types

All adapters normalize their wire formats into `agent_wire:message()` maps.
The `type` field is always present:

```erlang
-type message_type() :: text           %% Streaming text content
                      | assistant      %% Full assistant message with content blocks
                      | tool_use       %% Agent requesting tool execution
                      | tool_result    %% Tool execution result
                      | system         %% System/init messages (subtypes: init, status, etc.)
                      | result         %% Query completion with stats
                      | error          %% Error message
                      | user           %% User message (echo/replay)
                      | control        %% Legacy control message
                      | control_request  %% Bidirectional control request
                      | control_response %% Bidirectional control response
                      | stream_event   %% Streaming progress event
                      | rate_limit_event %% Rate limit status
                      | tool_progress  %% Tool execution progress
                      | tool_use_summary %% Tool use summary
                      | thinking       %% Model thinking/reasoning content
                      | auth_status    %% Authentication status
                      | prompt_suggestion %% Suggested follow-up prompts
                      | raw.           %% Unrecognized (preserved for forward compat)
```

### Result Message Fields

Result messages carry rich execution metadata:

```erlang
#{type := result,
  content := <<"Final answer text">>,
  duration_ms := 5432,
  duration_api_ms := 4200,
  num_turns := 3,
  session_id := <<"sess_abc123">>,
  stop_reason := <<"end_turn">>,
  stop_reason_atom := end_turn,
  usage := #{<<"input_tokens">> := 150, <<"output_tokens">> := 200},
  total_cost_usd := 0.0042,
  is_error := false}
```

### Assistant Message Content Blocks

Assistant messages contain parsed content blocks:

```erlang
#{type := assistant,
  content_blocks := [
      #{type := text, text := <<"Here's the answer...">>},
      #{type := tool_use, id := <<"toolu_123">>, name := <<"Bash">>,
        input := #{<<"command">> := <<"ls -la">>}},
      #{type := thinking, thinking := <<"Let me consider...">>}
  ]}
```

## Session Options

`agent_wire:session_opts()` is the unified option map accepted by all adapters.
Not all options apply to every adapter — each adapter ignores options not
relevant to its protocol.

### Common Options (All Adapters)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `cli_path` | `file:filename_all()` | varies | Path to CLI executable |
| `work_dir` | `file:filename_all()` | cwd | Working directory |
| `env` | `[{string(), string()}]` | `[]` | Extra environment variables |
| `buffer_max` | `pos_integer()` | 2097152 (2MB) | Max raw I/O buffer bytes |
| `queue_max` | `pos_integer()` | 10000 | Max queued messages |
| `model` | `binary()` | CLI default | Model to use |
| `system_prompt` | `binary() \| preset_map()` | CLI default | System prompt config |
| `max_turns` | `pos_integer()` | unlimited | Max conversation turns |
| `session_id` | `binary()` | auto | Session identifier |
| `sdk_hooks` | `[hook_def()]` | `[]` | SDK lifecycle hooks |
| `extra_args` | `#{binary() => binary() \| null}` | `#{}` | Extra CLI arguments |

### Claude Code Options

| Option | Type | Description |
|--------|------|-------------|
| `resume` | `boolean()` | Resume previous session |
| `fork_session` | `boolean()` | Fork from existing session |
| `continue` | `boolean()` | Continue last session |
| `persist_session` | `boolean()` | Persist session to disk |
| `permission_mode` | `binary() \| atom()` | `default`, `accept_edits`, `bypass_permissions`, `plan` |
| `permission_handler` | `fun/3` | Permission callback |
| `allowed_tools` | `[binary()]` | Whitelist tool names |
| `disallowed_tools` | `[binary()]` | Blacklist tool names |
| `agents` | `map()` | Subagent configurations |
| `mcp_servers` | `map()` | MCP server configurations |
| `sdk_mcp_servers` | `[sdk_mcp_server()]` | In-process MCP tool servers |
| `output_format` | `map()` | JSON schema for structured output |
| `thinking` | `map()` | Thinking/reasoning configuration |
| `effort` | `binary()` | Effort level |
| `max_budget_usd` | `number()` | Maximum cost budget |
| `enable_file_checkpointing` | `boolean()` | Enable file checkpoints |
| `plugins` | `[map()]` | Plugin configurations |
| `hooks` | `map()` | CLI-level hook configurations |
| `betas` | `[binary()]` | Beta features |
| `sandbox` | `map()` | Sandbox configuration |
| `debug` | `boolean()` | Enable debug mode |
| `client_app` | `binary()` | Client app identifier |

### Codex Options

| Option | Type | Description |
|--------|------|-------------|
| `transport` | `app_server \| exec` | Which Codex transport to use |
| `approval_handler` | `fun/3` | Approval callback |
| `approval_policy` | `binary()` | `"auto-edit"`, `"full-auto"`, etc. |
| `thread_id` | `binary()` | Thread to resume |
| `sandbox_mode` | `binary()` | Sandbox mode |
| `base_instructions` | `binary()` | Base system instructions |
| `developer_instructions` | `binary()` | Developer instructions |
| `ephemeral` | `boolean()` | Ephemeral session (no persistence) |

### Gemini CLI Options

| Option | Type | Description |
|--------|------|-------------|
| `approval_mode` | `binary()` | `"yolo"`, `"default"`, `"auto_edit"`, `"plan"` |
| `settings_file` | `binary()` | Path to custom settings.json |

### OpenCode Options

| Option | Type | Description |
|--------|------|-------------|
| `base_url` | `binary()` | OpenCode server URL (e.g., `"http://localhost:4096"`) |
| `directory` | `binary()` | Workspace directory (required) |
| `auth` | `{basic, User, Pass} \| none` | HTTP Basic Auth credentials |
| `provider_id` | `binary()` | AI provider (e.g., `"anthropic"`) |
| `model_id` | `binary()` | Model ID (e.g., `"claude-sonnet-4-20250514"`) |
| `agent` | `binary()` | OpenCode agent name |

## Query Options

`agent_wire:query_opts()` provides per-query overrides:

```erlang
claude_agent_sdk:query(Session, <<"Prompt">>, #{
    model => <<"claude-sonnet-4-20250514">>,
    system_prompt => <<"Be concise">>,
    max_tokens => 4096,
    timeout => 60000,
    permission_mode => <<"bypassPermissions">>,
    effort => <<"high">>,
    thinking => #{type => <<"enabled">>, budget_tokens => 10000}
}).
```

## SDK Lifecycle Hooks

Hooks are in-process callbacks that fire at session lifecycle points.

### Hook Events

| Event | Category | Can Deny? | Description |
|-------|----------|-----------|-------------|
| `pre_tool_use` | Blocking | Yes | Before a tool is executed |
| `user_prompt_submit` | Blocking | Yes | Before a user prompt is sent |
| `post_tool_use` | Notification | No | After tool execution completes |
| `stop` | Notification | No | When the session/query stops |
| `session_start` | Notification | No | When session initializes |
| `session_end` | Notification | No | When session terminates |

### Creating Hooks

```erlang
%% Simple notification hook
Hook1 = agent_wire_hooks:hook(post_tool_use, fun(Ctx) ->
    logger:info("Tool used: ~s", [maps:get(tool_name, Ctx, <<>>)]),
    ok
end),

%% Blocking hook with deny capability
Hook2 = agent_wire_hooks:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"Shell access disabled">>};
        _ -> ok
    end
end),

%% Hook with tool name matcher (only fires for specific tools)
Hook3 = agent_wire_hooks:hook(pre_tool_use, fun(_Ctx) ->
    {deny, <<"Read-only mode">>}
end, #{tool_name => <<"Write">>}),

%% Regex matcher
Hook4 = agent_wire_hooks:hook(post_tool_use, fun(Ctx) ->
    logger:info("File op: ~p", [Ctx]), ok
end, #{tool_name => <<"^(Read|Write|Edit)">>}).
```

## In-Process MCP Servers

Define custom tools as Erlang functions that the agent can call:

```erlang
%% Define a tool
Tool = agent_wire_mcp:tool(
    <<"get_weather">>,
    <<"Get weather for a city">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{
          <<"city">> => #{<<"type">> => <<"string">>}
      },
      <<"required">> => [<<"city">>]},
    fun(Input) ->
        City = maps:get(<<"city">>, Input, <<"unknown">>),
        {ok, [#{type => text, text => <<"72F in ", City/binary>>}]}
    end
),

%% Bundle tools into a server
Server = agent_wire_mcp:server(<<"weather-tools">>, [Tool]),

%% Pass to session
{ok, Session} = claude_agent_sdk:start_session(#{
    sdk_mcp_servers => [Server]
}).
```

Tool handlers return `{ok, [ContentItem]}` where each content item is:
- `#{type => text, text => Binary}` — Text result
- `#{type => image, data => Base64, mimeType => MimeType}` — Image result

## JSONL Parsing

```erlang
%% Parse a chunk of JSONL data (handles partial lines across chunks)
{Messages, RemainingBuffer} = agent_wire_jsonl:decode_lines(Data, Buffer).
```

## JSON-RPC 2.0 (Codex Protocol)

```erlang
%% Encode a request
ReqBin = agent_wire_jsonrpc:encode_request(<<"conversation/sendMessage">>,
    #{prompt => <<"Hello">>}, <<"req_1">>),

%% Decode a response
{ok, Decoded} = agent_wire_jsonrpc:decode(ResponseBin).
```

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[agent_wire, query, start]` | — | `#{session, prompt}` |
| `[agent_wire, query, stop]` | `#{duration}` | `#{session, message_count}` |
| `[agent_wire, query, exception]` | `#{duration}` | `#{session, reason}` |
| `[agent_wire, message, received]` | — | `#{session, type, message}` |
| `[agent_wire, session, start]` | — | `#{session, opts}` |
| `[agent_wire, session, stop]` | — | `#{session, reason}` |

## Transport Behaviour

Implement `agent_wire_transport` to create a custom transport:

```erlang
-behaviour(agent_wire_transport).

%% Required callbacks:
-callback start_link(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
-callback send_query(pid(), binary(), map(), timeout()) -> {ok, reference()} | {error, term()}.
-callback receive_message(pid(), reference(), timeout()) -> {ok, agent_wire:message()} | {error, term()}.
-callback send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
```
