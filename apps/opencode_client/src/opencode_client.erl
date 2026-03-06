%%%-------------------------------------------------------------------
%%% @doc Convenience API facade for the OpenCode HTTP agent SDK.
%%%
%%% Thin wrapper over opencode_session providing high-level functions
%%% for common use cases. Richer than port-based adapters because
%%% OpenCode exposes full HTTP REST capabilities.
%%%
%%% For fine-grained control, use opencode_session directly.
%%% Mirrors codex_app_server.erl patterns for API consistency.
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_client).

-export([
    %% Session lifecycle
    start_session/1,
    stop/1,
    child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Active query control
    abort/1,
    interrupt/1,
    %% Session info & runtime control
    session_info/1,
    set_model/2,
    set_permission_mode/2,
    health/1,
    %% Raw control messages
    send_control/3,
    %% SDK MCP server constructors
    mcp_tool/4,
    mcp_server/2,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3,
    %% OpenCode-specific REST operations
    list_server_sessions/1,
    get_server_session/2,
    delete_server_session/2,
    send_command/3,
    server_health/1,
    %% Universal: Session store (agent_wire)
    list_sessions/0,
    list_sessions/1,
    get_session_messages/1,
    get_session_messages/2,
    get_session/1,
    delete_session/1,
    %% Universal: Thread management (agent_wire)
    thread_start/2,
    thread_resume/2,
    thread_list/1,
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
    command_run/2,
    command_run/3,
    submit_feedback/2,
    turn_respond/3
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start an OpenCode HTTP session.
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    opencode_session:start_link(Opts).

%% @doc Stop an OpenCode session.
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for an opencode_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> opencode_session;
        SId when is_binary(SId) -> {opencode_session, SId};
        SId -> {opencode_session, SId}
    end,
    #{
        id       => Id,
        start    => {opencode_session, start_link, [Opts]},
        restart  => transient,
        shutdown => 10000,
        type     => worker,
        modules  => [opencode_session]
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
    case gen_statem:call(Session, {send_query, Prompt, Params}, Timeout) of
        {ok, Ref} ->
            ReceiveFun = fun(S, R, T) ->
                gen_statem:call(S, {receive_message, R}, T)
            end,
            agent_wire:collect_messages(Session, Ref, Deadline, ReceiveFun);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Active Query Control
%%====================================================================

%% @doc Abort the current active query.
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    gen_statem:call(Session, abort, 10000).

%% @doc Interrupt the current query. Alias for abort/1.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    abort(Session).

%%====================================================================
%% Session Info & Runtime Control
%%====================================================================

%% @doc Query session info (session id, directory, model, transport).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).

%% @doc Change the model at runtime.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).

%% @doc Change the permission mode at runtime via universal control.
-spec set_permission_mode(pid(), binary()) -> {ok, map()}.
set_permission_mode(Session, Mode) ->
    SessionId = get_session_id(Session),
    agent_wire_control:set_permission_mode(SessionId, Mode),
    {ok, #{permission_mode => Mode}}.

%% @doc Query session health state.
-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).

%% @doc Send a raw control message via universal control dispatch.
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    SessionId = get_session_id(Session),
    agent_wire_control:dispatch(SessionId, Method, Params).

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
%% OpenCode-specific REST Operations
%%====================================================================

%% @doc List all active sessions on the OpenCode server.
%%      This is the native OpenCode REST endpoint.
%%      For universal session history, use list_sessions/0,1.
-spec list_server_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_server_sessions(Session) ->
    gen_statem:call(Session, list_sessions, 10000).

%% @doc Get details for a specific session by ID from the OpenCode server.
%%      This is the native OpenCode REST endpoint.
%%      For universal session lookup, use get_session/1.
-spec get_server_session(pid(), binary()) -> {ok, map()} | {error, term()}.
get_server_session(Session, Id) ->
    gen_statem:call(Session, {get_session, Id}, 10000).

%% @doc Delete a session by ID on the OpenCode server.
%%      This is the native OpenCode REST endpoint.
%%      For universal session deletion, use delete_session/1.
-spec delete_server_session(pid(), binary()) -> {ok, term()} | {error, term()}.
delete_server_session(Session, Id) ->
    gen_statem:call(Session, {delete_session, Id}, 10000).

%% @doc Send a command to the current session.
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    gen_statem:call(Session, {send_command, Command, Params}, 30000).

%% @doc Check the health of the OpenCode server.
%%      This is the native OpenCode REST health endpoint.
-spec server_health(pid()) -> {ok, map()} | {error, term()}.
server_health(Session) ->
    gen_statem:call(Session, server_health, 5000).

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
%% Universal: Thread Management (agent_wire)
%%====================================================================

%% @doc Start a new conversation thread.
-spec thread_start(pid(), map()) -> {ok, map()}.
thread_start(Session, Opts) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:start_thread(SessionId, Opts).

%% @doc Resume an existing thread.
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_resume(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:resume_thread(SessionId, ThreadId).

%% @doc List all threads for this session.
-spec thread_list(pid()) -> {ok, [map()]}.
thread_list(Session) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:list_threads(SessionId).

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

%% @doc Run a command via universal command execution.
-spec command_run(pid(), binary()) ->
    {ok, agent_wire_command:command_result()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

%% @doc Run a command with options via universal command execution.
-spec command_run(pid(), binary(), map()) ->
    {ok, agent_wire_command:command_result()} | {error, term()}.
command_run(Session, Command, Opts) ->
    SessionId = get_session_id(Session),
    CmdOpts = case agent_wire_session_store:get_session(SessionId) of
        {ok, #{cwd := Cwd}} -> maps:merge(#{cwd => Cwd}, Opts);
        _ -> Opts
    end,
    agent_wire_command:run(Command, CmdOpts).

%% @doc Submit feedback via universal feedback tracking.
-spec submit_feedback(pid(), map()) -> ok.
submit_feedback(Session, Feedback) ->
    SessionId = get_session_id(Session),
    agent_wire_control:submit_feedback(SessionId, Feedback).

%% @doc Respond to an agent request via universal turn response.
-spec turn_respond(pid(), binary(), map()) ->
    ok | {error, not_found | already_resolved}.
turn_respond(Session, RequestId, Params) ->
    SessionId = get_session_id(Session),
    agent_wire_control:resolve_pending_request(SessionId, RequestId, Params).

%%====================================================================
%% Internal
%%====================================================================

%% @doc Get session ID from the session process.
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}} -> SId;
        _ -> unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

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

-spec extract_from_system_info(map(), atom(), term()) -> {ok, term()}.
extract_from_system_info(Info, Key, Default) ->
    case maps:find(system_info, Info) of
        {ok, SI} when is_map(SI) ->
            {ok, maps:get(Key, SI, Default)};
        _ ->
            {ok, Default}
    end.
