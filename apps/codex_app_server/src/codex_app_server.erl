%%%-------------------------------------------------------------------
%%% @doc Convenience API for the Codex CLI agent SDK.
%%%
%%% Thin wrapper over codex_session and codex_exec providing high-level
%%% functions for common use cases. For fine-grained control, use
%%% codex_session or codex_exec directly.
%%%
%%% Mirrors claude_agent_sdk.erl patterns for API consistency.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_app_server).

-export([
    %% Session lifecycle
    start_session/1,
    start_exec/1,
    stop/1,
    child_spec/1,
    exec_child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Thread management (native Codex — app-server only)
    thread_start/2,
    thread_resume/2,
    thread_list/1,
    %% Session info
    session_info/1,
    %% Runtime control
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    %% Raw control messages
    send_control/3,
    %% Health
    health/1,
    %% SDK MCP server constructors
    mcp_tool/4,
    mcp_server/2,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3,
    %% Codex-specific operations (app-server only)
    command_run/2,
    command_run/3,
    submit_feedback/2,
    turn_respond/3,
    %% Universal: Session store (agent_wire)
    list_sessions/0,
    list_sessions/1,
    get_session_messages/1,
    get_session_messages/2,
    get_session/1,
    delete_session/1,
    %% Universal: MCP management (agent_wire)
    mcp_server_status/1,
    set_mcp_servers/2,
    reconnect_mcp_server/2,
    toggle_mcp_server/3,
    %% Universal: Init response accessors
    supported_commands/1,
    supported_models/1,
    supported_agents/1,
    account_info/1,
    %% Universal: Session Control (agent_wire)
    set_max_thinking_tokens/2,
    rewind_files/2,
    stop_task/2,
    server_health/1
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start a Codex app-server session (full bidirectional JSON-RPC).
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    codex_session:start_link(Opts).

%% @doc Start a Codex exec session (one-shot JSONL queries).
-spec start_exec(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_exec(Opts) ->
    codex_exec:start_link(Opts).

%% @doc Stop a session (either app-server or exec).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for a codex_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> codex_session;
        SId when is_binary(SId) -> {codex_session, SId};
        SId -> {codex_session, SId}
    end,
    #{
        id => Id,
        start => {codex_session, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [codex_session]
    }.

%% @doc Supervisor child specification for a codex_exec process.
-spec exec_child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
exec_child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> codex_exec;
        SId when is_binary(SId) -> {codex_exec, SId};
        SId -> {codex_exec, SId}
    end,
    #{
        id => Id,
        start => {codex_exec, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [codex_exec]
    }.

%%====================================================================
%% Blocking Query
%%====================================================================

%% @doc Send a query and collect all response messages (blocking).
-spec query(pid(), binary()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

%% @doc Send a query with parameters, collect all messages (blocking).
%%      Uses deadline-based timeout.
-spec query(pid(), binary(), agent_wire:query_opts()) ->
    {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            agent_wire:collect_messages(Session, Ref, Deadline,
                fun receive_message_from/3);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Thread Management (native Codex — app-server only)
%%====================================================================

%% @doc Start a new conversation thread.
%%      Routes through gen_statem:call so both transports are supported.
%%      Returns `{error, not_supported}' for exec sessions.
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) ->
    send_control_to(Session, <<"thread/start">>,
        codex_protocol:thread_start_params(Opts)).

%% @doc Resume an existing thread by ID.
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) ->
    send_control_to(Session, <<"thread/resume">>,
        #{<<"threadId">> => ThreadId}).

%% @doc List all threads.
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) ->
    send_control_to(Session, <<"thread/list">>, #{}).

%%====================================================================
%% Session Info & Runtime Control
%%====================================================================

%% @doc Query session info.  Works with both app-server and exec sessions.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).

%% @doc Change the model at runtime.  Works with both transports.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).

%% @doc Change the permission mode at runtime.
%%      App-server sessions route through codex_session; exec returns
%%      {error, not_supported}.
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Session, Mode) ->
    gen_statem:call(Session, {set_permission_mode, Mode}, 5000).

%% @doc Interrupt the current turn/query.  Works with both transports.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).

%% @doc Abort the current turn/query. Alias for interrupt/1.
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).

%% @doc Send a raw control message (JSON-RPC method + params).
%%      App-server sessions dispatch via codex_session; exec returns
%%      {error, not_supported}.
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    send_control_to(Session, Method, Params).

%%====================================================================
%% Health
%%====================================================================

%% @doc Query session health state.  Works with both app-server and exec sessions.
-spec health(pid()) -> ready | connecting | initializing | active_turn | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).

%%====================================================================
%% SDK MCP Server Constructors
%%====================================================================

%% @doc Create an in-process MCP tool definition.
-spec mcp_tool(binary(), binary(), map(), agent_wire_mcp:tool_handler()) ->
    agent_wire_mcp:tool_def().
mcp_tool(Name, Description, InputSchema, Handler) ->
    agent_wire_mcp:tool(Name, Description, InputSchema, Handler).

%% @doc Create an in-process MCP server definition.
-spec mcp_server(binary(), [agent_wire_mcp:tool_def()]) ->
    agent_wire_mcp:sdk_mcp_server().
mcp_server(Name, Tools) ->
    agent_wire_mcp:server(Name, Tools).

%%====================================================================
%% SDK Hook Constructors
%%====================================================================

%% @doc Create an SDK lifecycle hook.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback) ->
    agent_wire_hooks:hook(Event, Callback).

%% @doc Create an SDK lifecycle hook with a matcher.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback(),
               agent_wire_hooks:hook_matcher()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    agent_wire_hooks:hook(Event, Callback, Matcher).

%%====================================================================
%% Codex-Specific Operations (app-server only)
%%====================================================================

%% @doc Run a command in the Codex sandbox.
%%      Returns {error, not_supported} for exec sessions.
-spec command_run(pid(), binary()) -> {ok, term()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

%% @doc Run a command in the Codex sandbox with options.
%%      Options may include timeout, working directory, etc.
-spec command_run(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
command_run(Session, Command, Opts) ->
    Params = Opts#{<<"command">> => Command},
    send_control_to(Session, <<"command/exec">>, Params).

%% @doc Submit a feedback report to the Codex server.
%%      Feedback is a map with content, type, and optional metadata.
-spec submit_feedback(pid(), map()) -> {ok, term()} | {error, term()}.
submit_feedback(Session, Feedback) when is_map(Feedback) ->
    send_control_to(Session, <<"feedback/upload">>, Feedback).

%% @doc Respond to an agent request (approval, user input, etc.).
%%      RequestId is the JSON-RPC request ID to respond to.
%%      Params contains the response data.
-spec turn_respond(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
turn_respond(Session, RequestId, Params) ->
    send_control_to(Session, <<"turn/respond">>,
        Params#{<<"requestId">> => RequestId}).

%%====================================================================
%% Universal: Session Store (agent_wire)
%%====================================================================

%% @doc List all tracked sessions.
-spec list_sessions() -> {ok, [agent_wire_session_store:session_meta()]}.
list_sessions() ->
    agent_wire_session_store:list_sessions().

%% @doc List sessions with filters.
-spec list_sessions(agent_wire_session_store:list_opts()) ->
    {ok, [agent_wire_session_store:session_meta()]}.
list_sessions(Opts) ->
    agent_wire_session_store:list_sessions(Opts).

%% @doc Get messages for a session.
-spec get_session_messages(binary()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    agent_wire_session_store:get_session_messages(SessionId).

%% @doc Get messages with options.
-spec get_session_messages(binary(), agent_wire_session_store:message_opts()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) ->
    agent_wire_session_store:get_session_messages(SessionId, Opts).

%% @doc Get session metadata by ID.
-spec get_session(binary()) ->
    {ok, agent_wire_session_store:session_meta()} | {error, not_found}.
get_session(SessionId) ->
    agent_wire_session_store:get_session(SessionId).

%% @doc Delete a session and its messages.
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    agent_wire_session_store:delete_session(SessionId).

%%====================================================================
%% Universal: MCP Management (agent_wire)
%%====================================================================

%% @doc Get status of all MCP servers.
-spec mcp_server_status(pid()) -> {ok, map()}.
mcp_server_status(Session) ->
    case agent_wire_mcp:get_session_registry(Session) of
        {ok, Registry} -> agent_wire_mcp:server_status(Registry);
        {error, not_found} -> {ok, #{}}
    end.

%% @doc Replace MCP server configurations.
-spec set_mcp_servers(pid(), [agent_wire_mcp:sdk_mcp_server()]) ->
    {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    case agent_wire_mcp:update_session_registry(Session,
        fun(R) -> agent_wire_mcp:set_servers(Servers, R) end) of
        ok -> {ok, #{<<"status">> => <<"updated">>}};
        {error, _} = Err -> Err
    end.

%% @doc Reconnect a failed MCP server.
-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Session, ServerName) ->
    case agent_wire_mcp:get_session_registry(Session) of
        {ok, Registry} ->
            case agent_wire_mcp:reconnect_server(ServerName, Registry) of
                {ok, Updated} ->
                    agent_wire_mcp:register_session_registry(Session, Updated),
                    {ok, #{<<"status">> => <<"reconnected">>}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

%% @doc Enable or disable an MCP server.
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
    {ok, term()} | {error, term()}.
toggle_mcp_server(Session, ServerName, Enabled) ->
    case agent_wire_mcp:get_session_registry(Session) of
        {ok, Registry} ->
            case agent_wire_mcp:toggle_server(ServerName, Enabled, Registry) of
                {ok, Updated} ->
                    agent_wire_mcp:register_session_registry(Session, Updated),
                    {ok, #{<<"status">> => <<"toggled">>}};
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Universal: Init Response Accessors
%%====================================================================

%% @doc List available slash commands from session init data.
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) ->
    extract_init_field(Session, commands, slash_commands, []).

%% @doc List available models from session init data.
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) ->
    extract_init_field(Session, models, models, []).

%% @doc List available agents from session init data.
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) ->
    extract_init_field(Session, agents, agents, []).

%% @doc Get account information from session init data.
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) ->
    extract_init_field(Session, account, account, #{}).

%%====================================================================
%% Universal: Session Control (agent_wire)
%%====================================================================

%% @doc Set maximum thinking tokens via universal control.
-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, map()}.
set_max_thinking_tokens(Session, MaxTokens) when is_integer(MaxTokens), MaxTokens > 0 ->
    SessionId = get_session_id(Session),
    agent_wire_control:set_max_thinking_tokens(SessionId, MaxTokens),
    {ok, #{max_thinking_tokens => MaxTokens}}.

%% @doc Revert file changes to a checkpoint via universal checkpointing.
-spec rewind_files(pid(), binary()) -> ok | {error, not_found | term()}.
rewind_files(Session, CheckpointUuid) ->
    SessionId = get_session_id(Session),
    agent_wire_checkpoint:rewind(SessionId, CheckpointUuid).

%% @doc Stop a running agent task via universal task tracking.
-spec stop_task(pid(), binary()) -> ok | {error, not_found}.
stop_task(Session, TaskId) ->
    SessionId = get_session_id(Session),
    agent_wire_control:stop_task(SessionId, TaskId).

%% @doc Check server health. Maps to session health for Codex.
-spec server_health(pid()) -> {ok, map()}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => codex}}.

%%====================================================================
%% Internal
%%====================================================================

%% @doc Route query to the appropriate session module.
%%      Works with both codex_session and codex_exec via gen_statem:call.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    gen_statem:call(Session, {send_query, Prompt, Params}, Timeout).

%% @doc Route control message to the session.
%%      codex_session processes the request; codex_exec returns {error, not_supported}.
-spec send_control_to(pid(), binary(), map()) ->
    {ok, term()} | {error, term()}.
send_control_to(Session, Method, Params) ->
    gen_statem:call(Session, {send_control, Method, Params}, 30000).

-spec receive_message_from(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).

%% @doc Extract a field from session init data.
%%      Checks init_response first (Claude-style), then system_info.
-spec extract_init_field(pid(), atom(), atom(), term()) ->
    {ok, term()} | {error, term()}.
extract_init_field(Session, IRKey, SIKey, Default) ->
    case session_info(Session) of
        {ok, Info} ->
            %% Try init_response (Claude-style) first
            case maps:find(init_response, Info) of
                {ok, IR} when is_map(IR) ->
                    IRKeyBin = atom_to_binary(IRKey),
                    case maps:find(IRKeyBin, IR) of
                        {ok, Val} -> {ok, Val};
                        error -> extract_from_system_info(Info, SIKey, Default)
                    end;
                _ ->
                    extract_from_system_info(Info, SIKey, Default)
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc Get session ID from the session process.
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}} -> SId;
        _ -> unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

-spec extract_from_system_info(map(), atom(), term()) -> {ok, term()}.
extract_from_system_info(Info, Key, Default) ->
    case maps:find(system_info, Info) of
        {ok, SI} when is_map(SI) ->
            {ok, maps:get(Key, SI, Default)};
        _ ->
            {ok, Default}
    end.
