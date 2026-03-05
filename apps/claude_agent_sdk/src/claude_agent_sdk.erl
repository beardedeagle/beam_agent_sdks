%%%-------------------------------------------------------------------
%%% @doc Convenience API for the Claude Code agent SDK.
%%%
%%% Thin wrapper over claude_agent_session providing high-level
%%% functions for common use cases. For fine-grained control, use
%%% claude_agent_session directly.
%%%
%%% Cross-referenced against TS SDK v0.2.66 for API parity:
%%%   - query/2,3 — blocking query with message collection
%%%   - session_info/1 — query session capabilities
%%%   - set_model/2 — change model at runtime
%%%   - set_permission_mode/2 — change permission mode at runtime
%%%   - set_max_thinking_tokens/2 — adjust thinking budget
%%%   - rewind_files/2 — revert to a file checkpoint
%%%   - stop_task/2 — cancel a running agent task
%%%   - mcp_server_status/1 — check MCP server health
%%%   - set_mcp_servers/2 — dynamic MCP server management
%%%   - reconnect_mcp_server/2 — reconnect failed MCP server
%%%   - toggle_mcp_server/3 — enable/disable MCP server
%%%   - supported_commands/1 — list available slash commands
%%%   - supported_models/1 — list available models
%%%   - supported_agents/1 — list available agents
%%%   - account_info/1 — get account details
%%%   - child_spec/1 — supervisor integration
%%% @end
%%%-------------------------------------------------------------------
-module(claude_agent_sdk).

-export([
    %% Session lifecycle
    start_session/1,
    stop/1,
    health/1,
    %% Blocking query
    query/2,
    query/3,
    session_info/1,
    set_model/2,
    set_permission_mode/2,
    set_max_thinking_tokens/2,
    rewind_files/2,
    stop_task/2,
    %% MCP management
    mcp_server_status/1,
    set_mcp_servers/2,
    reconnect_mcp_server/2,
    toggle_mcp_server/3,
    %% SDK MCP server constructors
    mcp_tool/4,
    mcp_server/2,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3,
    %% Session info accessors
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    account_info/1,
    child_spec/1,
    %% Session management utilities
    list_sessions/0,
    list_sessions/1,
    get_session_messages/1,
    get_session_messages/2
]).

-dialyzer({no_underspecs, [extract_init_field/3]}).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start a Claude Code session.
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    claude_agent_session:start_link(Opts).

%% @doc Stop a session.
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Query session health state.
-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).

%%====================================================================
%% Blocking Query
%%====================================================================

%% @doc Send a query and collect all response messages (blocking).
%%      Returns the complete list of messages once the query finishes.
-spec query(pid(), binary()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

%% @doc Send a query with parameters, collect all messages (blocking).
%%      Uses deadline-based timeout: the total wall-clock time for the
%%      entire query is bounded, not per-message.
-spec query(pid(), binary(), agent_wire:query_opts()) ->
    {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case claude_agent_session:send_query(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            agent_wire:collect_messages(Session, Ref, Deadline,
                fun claude_agent_session:receive_message/3);
        {error, _} = Err ->
            Err
    end.

%% @doc Query session capabilities and initialization data.
%%      Returns a map with session_id, system_info (parsed init metadata),
%%      and init_response (raw initialize control_response).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    claude_agent_session:session_info(Session).

%% @doc Change the model at runtime during a session.
%%      Model should be a binary like <<"claude-sonnet-4-20250514">>.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    claude_agent_session:set_model(Session, Model).

%% @doc Change the permission mode at runtime.
%%      Mode should be a binary like <<"acceptEdits">> or an atom
%%      like accept_edits (converted to wire format by the session).
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) ->
    claude_agent_session:set_permission_mode(Session, Mode).

%% @doc Revert file changes to a checkpoint identified by UUID.
%%      Only meaningful when file checkpointing is enabled in session opts.
-spec rewind_files(pid(), binary()) -> {ok, term()} | {error, term()}.
rewind_files(Session, CheckpointUuid) ->
    claude_agent_session:rewind_files(Session, CheckpointUuid).

%% @doc Stop a running agent task by task ID.
-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Session, TaskId) ->
    claude_agent_session:stop_task(Session, TaskId).

%% @doc Set the maximum thinking tokens at runtime.
-spec set_max_thinking_tokens(pid(), pos_integer()) ->
    {ok, term()} | {error, term()}.
set_max_thinking_tokens(Session, MaxTokens) ->
    claude_agent_session:set_max_thinking_tokens(Session, MaxTokens).

%% @doc Query MCP server health and status.
-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Session) ->
    claude_agent_session:mcp_server_status(Session).

%% @doc Dynamically add or replace MCP server configurations.
-spec set_mcp_servers(pid(), map()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    claude_agent_session:set_mcp_servers(Session, Servers).

%% @doc Reconnect a failed MCP server by name.
-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    claude_agent_session:reconnect_mcp_server(Session, ServerName).

%% @doc Enable or disable an MCP server at runtime.
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
    {ok, term()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    claude_agent_session:toggle_mcp_server(Session, ServerName, Enabled).

%% @doc List available slash commands from the init response.
%%      Returns the commands array from the initialize control_response,
%%      or an empty list if not yet initialized.
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) ->
    extract_init_field(Session, <<"commands">>, []).

%% @doc List available models from the init response.
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) ->
    extract_init_field(Session, <<"models">>, []).

%% @doc List available agents from the init response.
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) ->
    extract_init_field(Session, <<"agents">>, []).

%% @doc Get account information from the init response.
%%      Returns account details (email, org, subscription type, etc.)
%%      from the initialize control_response.
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) ->
    extract_init_field(Session, <<"account">>, #{}).

%% @doc Supervisor child specification for embedding a session
%%      in your supervision tree. Uses session_id from opts as child id
%%      when available, allowing multiple sessions under one supervisor.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> claude_agent_session;
        SId when is_binary(SId) -> {claude_agent_session, SId};
        SId -> {claude_agent_session, SId}
    end,
    #{
        id => Id,
        start => {claude_agent_session, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [claude_agent_session]
    }.

%%--------------------------------------------------------------------
%% SDK MCP Server Constructors
%%--------------------------------------------------------------------

%% @doc Create an in-process MCP tool definition.
%%      Convenience wrapper for agent_wire_mcp:tool/4.
-spec mcp_tool(binary(), binary(), map(), agent_wire_mcp:tool_handler()) ->
    agent_wire_mcp:tool_def().
mcp_tool(Name, Description, InputSchema, Handler) ->
    agent_wire_mcp:tool(Name, Description, InputSchema, Handler).

%% @doc Create an in-process MCP server definition.
%%      Convenience wrapper for agent_wire_mcp:server/2.
-spec mcp_server(binary(), [agent_wire_mcp:tool_def()]) ->
    agent_wire_mcp:sdk_mcp_server().
mcp_server(Name, Tools) ->
    agent_wire_mcp:server(Name, Tools).

%%--------------------------------------------------------------------
%% SDK Hook Constructors
%%--------------------------------------------------------------------

%% @doc Create an SDK lifecycle hook.
%%      Convenience wrapper for agent_wire_hooks:hook/2.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback) ->
    agent_wire_hooks:hook(Event, Callback).

%% @doc Create an SDK lifecycle hook with a matcher.
%%      Convenience wrapper for agent_wire_hooks:hook/3.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback(),
               agent_wire_hooks:hook_matcher()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    agent_wire_hooks:hook(Event, Callback, Matcher).

%%--------------------------------------------------------------------
%% Session Management Utilities
%%--------------------------------------------------------------------

%% @doc List session transcripts from the Claude config directory.
%%      Returns session summaries sorted by modified_at descending.
-spec list_sessions() ->
    {ok, [claude_session_store:session_summary()]}.
list_sessions() ->
    claude_session_store:list_sessions().

%% @doc List session transcripts with optional filters.
%%      Options: cwd, limit, config_dir.
-spec list_sessions(claude_session_store:list_opts()) ->
    {ok, [claude_session_store:session_summary()]}.
list_sessions(Opts) ->
    claude_session_store:list_sessions(Opts).

%% @doc Get all messages from a session transcript by ID.
-spec get_session_messages(binary()) ->
    {ok, [map()]} | {error, atom()}.
get_session_messages(SessionId) ->
    claude_session_store:get_session_messages(SessionId).

%% @doc Get all messages from a session transcript with options.
%%      Options: config_dir.
-spec get_session_messages(binary(), claude_session_store:message_opts()) ->
    {ok, [map()]} | {error, atom()}.
get_session_messages(SessionId, Opts) ->
    claude_session_store:get_session_messages(SessionId, Opts).

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% @doc Extract a field from the stored init_response via session_info.
-spec extract_init_field(pid(), binary(), term()) ->
    {ok, term()} | {error, term()}.
extract_init_field(Session, Field, Default) ->
    case session_info(Session) of
        {ok, #{init_response := IR}} when is_map(IR) ->
            {ok, maps:get(Field, IR, Default)};
        {ok, _} ->
            {ok, Default};
        {error, _} = Err ->
            Err
    end.

%% @doc Collect messages until result/error/complete, using a deadline
%%      (monotonic timestamp) so the total query time is bounded.
