# BEAM Agent SDKs

Erlang/OTP and Elixir SDKs for integrating AI coding agents into BEAM applications.

Five adapters, one unified message format. Connect to **Claude Code**, **Codex CLI**,
**Gemini CLI**, **OpenCode**, or **GitHub Copilot** from any Erlang or Elixir
application.

## Architecture

```
                              +-------------+
                              | agent_wire  |  Shared types, JSONL, hooks, MCP, telemetry
                              +------+------+
       +--------------+--------------++--------------+--------------+
       |              |              |               |              |
+------+------+ +-----+------+ +----+-------+ +-----+------+ +----+-------+
| claude_     | | codex_app  | | gemini_cli | | opencode   | | copilot    |
|  agent_sdk  | |  _server   | |  _client   | |  _client   | |  _client   |
| Port/JSONL  | | Port/JSONRPC| | Port/JSONL | | HTTP/SSE   | | Port/CLRPC |
+------+------+ +-----+------+ +----+-------+ +-----+------+ +----+-------+
       |              |              |               |              |
+------+------+ +-----+------+ +----+-------+ +-----+------+ +----+-------+
| ClaudeEx    | | CodexEx    | | GeminiEx   | | OpencodeEx | | CopilotEx  |
| (Elixir)    | | (Elixir)   | | (Elixir)   | | (Elixir)   | | (Elixir)   |
+-------------+ +------------+ +------------+ +------------+ +------------+
```

All five adapters normalize messages into `agent_wire:message()` — a common map
type you can pattern-match on regardless of which agent you're talking to.

## Quick Start

### Erlang

Add the adapter you need to your `rebar.config` deps:

```erlang
{deps, [
    {claude_agent_sdk, {path, "apps/claude_agent_sdk"}},
    {agent_wire, {path, "apps/agent_wire"}}
]}.
```

```erlang
%% Start a Claude Code session
{ok, Session} = claude_agent_sdk:start_session(#{
    cli_path => "/usr/local/bin/claude",
    permission_mode => <<"bypassPermissions">>
}),

%% Blocking query — returns all messages
{ok, Messages} = claude_agent_sdk:query(Session, <<"Explain OTP supervisors">>),

%% Find the result
[Result | _] = [M || #{type := result} = M <- Messages],
io:format("~s~n", [maps:get(content, Result, <<>>)]),

claude_agent_sdk:stop(Session).
```

### Elixir

```elixir
# In mix.exs
defp deps do
  [{:claude_ex, path: "wrappers/claude_ex"}]
end
```

```elixir
{:ok, session} = ClaudeEx.start_session(cli_path: "claude")

# Streaming query — lazy enumerable
session
|> ClaudeEx.stream!("Explain GenServer")
|> Enum.each(fn msg ->
  case msg.type do
    :text -> IO.write(msg.content)
    :result -> IO.puts("\n--- Done ---")
    _ -> :ok
  end
end)

ClaudeEx.stop(session)
```

## Adapters at a Glance

| Adapter | CLI | Transport | Protocol | Bidirectional |
|---------|-----|-----------|----------|---------------|
| `claude_agent_sdk` | `claude` | Port | JSONL | Yes (control protocol) |
| `codex_app_server` | `codex` | Port | JSON-RPC / JSONL | Yes (app-server) or No (exec) |
| `gemini_cli_client` | `gemini` | Port | JSONL | No (one-shot per query) |
| `opencode_client` | `opencode serve` | HTTP + SSE | REST + SSE | Yes |
| `copilot_client` | `copilot` | Port | JSON-RPC / Content-Length | Yes (bidirectional) |

## Common API Surface

Every adapter exposes this consistent API:

```erlang
start_session(Opts)    -> {ok, Pid} | {error, Reason}
stop(Pid)              -> ok
query(Pid, Prompt)     -> {ok, [Message]} | {error, Reason}
query(Pid, Prompt, Params) -> {ok, [Message]} | {error, Reason}
health(Pid)            -> ready | connecting | initializing | active_query | error
session_info(Pid)      -> {ok, Map} | {error, Reason}
child_spec(Opts)       -> supervisor:child_spec()
sdk_hook(Event, Callback) -> hook_def()
```

Elixir wrappers add `stream!/3` and `stream/3` (lazy `Stream.resource/3`-based
enumerables) on top of this common surface.

## Unified Message Format

All adapters normalize messages to `agent_wire:message()`:

```erlang
#{type := text, content := <<"Hello!">>}
#{type := tool_use, tool_name := <<"Bash">>, tool_input := #{...}}
#{type := tool_result, tool_name := <<"Bash">>, content := <<"output...">>}
#{type := result, content := <<"Final answer">>, duration_ms := 5432}
#{type := error, content := <<"Something went wrong">>}
#{type := thinking, content := <<"Let me consider...">>}
#{type := system, subtype := <<"init">>, system_info := #{...}}
```

Pattern match on `type` for dispatch:

```erlang
handle_message(#{type := text, content := Content}) ->
    io:format("~s", [Content]);
handle_message(#{type := tool_use, tool_name := Name}) ->
    io:format("Using tool: ~s~n", [Name]);
handle_message(#{type := result} = Msg) ->
    io:format("Done! Cost: $~.4f~n", [maps:get(total_cost_usd, Msg, 0.0)]);
handle_message(_Other) ->
    ok.
```

## SDK Features

### In-Process MCP Servers (Claude Code)

Define custom tools as Erlang functions that Claude can call:

```erlang
Tool = agent_wire_mcp:tool(
    <<"lookup_user">>,
    <<"Look up a user by ID">>,
    #{<<"type">> => <<"object">>,
      <<"properties">> => #{<<"id">> => #{<<"type">> => <<"string">>}}},
    fun(Input) ->
        Id = maps:get(<<"id">>, Input, <<>>),
        {ok, [#{type => text, text => <<"User: ", Id/binary>>}]}
    end
),
Server = agent_wire_mcp:server(<<"my-tools">>, [Tool]),
{ok, Session} = claude_agent_sdk:start_session(#{sdk_mcp_servers => [Server]}).
```

### SDK Lifecycle Hooks

Register callbacks at key session lifecycle points:

```erlang
%% Block dangerous tool calls
Hook = agent_wire_hooks:hook(pre_tool_use, fun(Ctx) ->
    case maps:get(tool_name, Ctx, <<>>) of
        <<"Bash">> -> {deny, <<"Shell access denied">>};
        _ -> ok
    end
end),
{ok, Session} = claude_agent_sdk:start_session(#{sdk_hooks => [Hook]}).
```

Hook events: `pre_tool_use`, `post_tool_use`, `user_prompt_submit`, `stop`,
`session_start`, `session_end`.

### Telemetry

All adapters emit `telemetry` events:

```erlang
telemetry:attach(my_handler, [agent_wire, query, stop], fun handle/4, #{}).
```

Events: `[agent_wire, query, start|stop|exception]`,
`[agent_wire, message, received]`, `[agent_wire, session, start|stop]`.

### Supervisor Integration

Embed sessions in your supervision tree:

```erlang
%% In your supervisor init/1
Children = [
    claude_agent_sdk:child_spec(#{
        cli_path => "/usr/local/bin/claude",
        session_id => <<"worker-1">>
    })
],
{ok, {#{strategy => one_for_one}, Children}}.
```

## Project Structure

```
beam_agent_sdks/
  apps/
    agent_wire/           Shared foundation (types, JSONL, hooks, MCP, telemetry)
    claude_agent_sdk/     Claude Code adapter (Port/JSONL + control protocol)
    codex_app_server/     Codex CLI adapter (Port/JSON-RPC + exec fallback)
    gemini_cli_client/    Gemini CLI adapter (Port/JSONL, one-shot per query)
    opencode_client/      OpenCode adapter (HTTP REST + SSE via gun)
    copilot_client/       Copilot adapter (Port/JSON-RPC + Content-Length)
  wrappers/
    claude_ex/            Elixir wrapper for Claude Code
    codex_ex/             Elixir wrapper for Codex CLI
    gemini_ex/            Elixir wrapper for Gemini CLI
    opencode_ex/          Elixir wrapper for OpenCode
    copilot_ex/           Elixir wrapper for GitHub Copilot
```

## Building

### Erlang

```bash
rebar3 compile          # Build all apps
rebar3 eunit            # Run all tests
rebar3 dialyzer         # Static analysis
rebar3 check            # compile + dialyzer + eunit + ct
```

### Elixir Wrappers

```bash
cd wrappers/claude_ex && mix compile && mix test
cd wrappers/codex_ex && mix compile && mix test
cd wrappers/gemini_ex && mix compile && mix test
cd wrappers/opencode_ex && mix compile && mix test
cd wrappers/copilot_ex && mix compile && mix test
```

## Requirements

- Erlang/OTP 27+
- Elixir 1.17+ (for wrappers)
- `telemetry` ~> 1.3
- `gun` ~> 2.1 (only for `opencode_client`)
- Test deps: `proper` ~> 1.4, `meck` ~> 0.9

## Per-App Documentation

Each app and wrapper has its own README with full API reference, configuration
options, examples, and intentional omissions with workarounds:

**Erlang Apps:**
- [agent_wire](apps/agent_wire/README.md) — Shared foundation
- [claude_agent_sdk](apps/claude_agent_sdk/README.md) — Claude Code adapter
- [codex_app_server](apps/codex_app_server/README.md) — Codex CLI adapter
- [gemini_cli_client](apps/gemini_cli_client/README.md) — Gemini CLI adapter
- [opencode_client](apps/opencode_client/README.md) — OpenCode adapter
- [copilot_client](apps/copilot_client/README.md) — GitHub Copilot adapter

**Elixir Wrappers:**
- [ClaudeEx](wrappers/claude_ex/README.md)
- [CodexEx](wrappers/codex_ex/README.md)
- [GeminiEx](wrappers/gemini_ex/README.md)
- [OpencodeEx](wrappers/opencode_ex/README.md)
- [CopilotEx](wrappers/copilot_ex/README.md)

## License

See individual app directories for license information.
