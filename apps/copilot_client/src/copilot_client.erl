-module(copilot_client).

-moduledoc """
Convenience API for the Copilot CLI agent SDK.

Thin wrapper over copilot_session providing high-level functions
for common use cases. For fine-grained control, use
copilot_session directly.

Mirrors `codex_app_server.erl` / `claude_agent_sdk.erl` patterns
for API consistency across all BEAM agent SDK adapters.
""".

-export([
    %% Session lifecycle
    start_session/1,
    stop/1,
    child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Session info
    session_info/1,
    %% Runtime control
    set_model/2,
    set_permission_mode/2,
    interrupt/1,
    abort/1,
    %% Health
    health/1,
    %% Control messages
    send_command/3,
    send_control/3,
    %% SDK MCP server constructors
    mcp_tool/4,
    mcp_server/2,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3,
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
    turn_respond/3,
    server_health/1
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

-doc "Start a Copilot session (full bidirectional JSON-RPC via stdio).".
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    copilot_session:start_link(Opts).

-doc "Stop a session.".
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

-doc "Supervisor child specification for a copilot_session process.".
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> copilot_session;
        SId when is_binary(SId) -> {copilot_session, SId};
        SId -> {copilot_session, SId}
    end,
    #{
        id => Id,
        start => {copilot_session, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [copilot_session]
    }.

%%====================================================================
%% Blocking Query
%%====================================================================

-doc "Send a query and collect all response messages (blocking).".
-spec query(pid(), binary()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

-doc """
Send a query with params and collect all response messages.
Blocks until `session.idle` event or timeout.
""".
-spec query(pid(), binary(), map()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            collect_messages(Session, Ref, Deadline, []);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Session Info
%%====================================================================

-doc "Get session info (adapter, session_id, model, etc.).".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    copilot_session:session_info(Session).

%%====================================================================
%% Runtime Control
%%====================================================================

-doc "Change the model for this session.".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    copilot_session:set_model(Session, Model).

-doc "Abort the current query. Alias for `interrupt/1`.".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    copilot_session:interrupt(Session).

-doc "Abort the current query.".
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).

%%====================================================================
%% Health
%%====================================================================

-doc "Get the current health state.".
-spec health(pid()) -> atom().
health(Session) ->
    copilot_session:health(Session).

-doc "Change the permission mode at runtime via universal control.".
-spec set_permission_mode(pid(), binary()) -> {ok, map()}.
set_permission_mode(Session, Mode) ->
    SessionId = get_session_id(Session),
    agent_wire_control:set_permission_mode(SessionId, Mode),
    {ok, #{permission_mode => Mode}}.

%%====================================================================
%% Control Messages
%%====================================================================

-doc "Send an arbitrary JSON-RPC command to the Copilot CLI.".
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Method, Params) ->
    copilot_session:send_control(Session, Method, Params).

-doc "Send a raw control message. Routes through `send_command`.".
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Session, Method, Params) ->
    send_command(Session, Method, Params).

%%====================================================================
%% SDK MCP Server Constructors
%%====================================================================

-doc "Create an in-process MCP tool definition.".
-spec mcp_tool(binary(), binary(), map(), agent_wire_mcp:tool_handler()) ->
    agent_wire_mcp:tool_def().
mcp_tool(Name, Description, InputSchema, Handler) ->
    agent_wire_mcp:tool(Name, Description, InputSchema, Handler).

-doc "Create an in-process MCP server definition.".
-spec mcp_server(binary(), [agent_wire_mcp:tool_def()]) ->
    agent_wire_mcp:sdk_mcp_server().
mcp_server(Name, Tools) ->
    agent_wire_mcp:server(Name, Tools).

%%====================================================================
%% SDK Hook Constructors
%%====================================================================

-doc "Create an SDK hook definition (without matcher).".
-spec sdk_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_callback()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback) ->
    agent_wire_hooks:hook(Event, Callback).

-doc "Create an SDK hook definition (with matcher).".
-spec sdk_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_callback(),
               agent_wire_hooks:hook_matcher()) -> agent_wire_hooks:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    agent_wire_hooks:hook(Event, Callback, Matcher).

%%====================================================================
%% Universal: Session Store (agent_wire)
%%====================================================================

-doc "List all tracked sessions.".
-spec list_sessions() -> {ok, [agent_wire_session_store:session_meta()]}.
list_sessions() ->
    agent_wire_session_store:list_sessions().

-doc "List sessions with filters.".
-spec list_sessions(agent_wire_session_store:list_opts()) ->
    {ok, [agent_wire_session_store:session_meta()]}.
list_sessions(Opts) ->
    agent_wire_session_store:list_sessions(Opts).

-doc "Get messages for a session.".
-spec get_session_messages(binary()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    agent_wire_session_store:get_session_messages(SessionId).

-doc "Get messages with options.".
-spec get_session_messages(binary(), agent_wire_session_store:message_opts()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts) ->
    agent_wire_session_store:get_session_messages(SessionId, Opts).

-doc "Get session metadata by ID.".
-spec get_session(binary()) ->
    {ok, agent_wire_session_store:session_meta()} | {error, not_found}.
get_session(SessionId) ->
    agent_wire_session_store:get_session(SessionId).

-doc "Delete a session and its messages.".
-spec delete_session(binary()) -> ok.
delete_session(SessionId) ->
    agent_wire_session_store:delete_session(SessionId).

%%====================================================================
%% Universal: Thread Management (agent_wire)
%%====================================================================

-doc "Start a new conversation thread.".
-spec thread_start(pid(), map()) -> {ok, map()}.
thread_start(Session, Opts) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:start_thread(SessionId, Opts).

-doc "Resume an existing thread.".
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, not_found}.
thread_resume(Session, ThreadId) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:resume_thread(SessionId, ThreadId).

-doc "List all threads for this session.".
-spec thread_list(pid()) -> {ok, [map()]}.
thread_list(Session) ->
    SessionId = get_session_id(Session),
    agent_wire_threads:list_threads(SessionId).

%%====================================================================
%% Universal: MCP Management (agent_wire)
%%====================================================================

-doc "Get status of all MCP servers.".
-spec mcp_server_status(pid()) -> {ok, map()}.
mcp_server_status(Session) ->
    case agent_wire_mcp:get_session_registry(Session) of
        {ok, Registry} -> agent_wire_mcp:server_status(Registry);
        {error, not_found} -> {ok, #{}}
    end.

-doc "Replace MCP server configurations.".
-spec set_mcp_servers(pid(), [agent_wire_mcp:sdk_mcp_server()]) ->
    {ok, term()} | {error, term()}.
set_mcp_servers(Session, Servers) ->
    case agent_wire_mcp:update_session_registry(Session,
        fun(R) -> agent_wire_mcp:set_servers(Servers, R) end) of
        ok -> {ok, #{<<"status">> => <<"updated">>}};
        {error, _} = Err -> Err
    end.

-doc "Reconnect a failed MCP server.".
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

-doc "Enable or disable an MCP server.".
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

-doc "List available slash commands from session init data.".
-spec supported_commands(pid()) -> {ok, list()} | {error, term()}.
supported_commands(Session) ->
    extract_init_field(Session, commands, slash_commands, []).

-doc "List available models from session init data.".
-spec supported_models(pid()) -> {ok, list()} | {error, term()}.
supported_models(Session) ->
    extract_init_field(Session, models, models, []).

-doc "List available agents from session init data.".
-spec supported_agents(pid()) -> {ok, list()} | {error, term()}.
supported_agents(Session) ->
    extract_init_field(Session, agents, agents, []).

-doc "Get account information from session init data.".
-spec account_info(pid()) -> {ok, map()} | {error, term()}.
account_info(Session) ->
    extract_init_field(Session, account, account, #{}).

%%====================================================================
%% Universal: Session Control (agent_wire)
%%====================================================================

-doc "Set maximum thinking tokens via universal control.".
-spec set_max_thinking_tokens(pid(), pos_integer()) -> {ok, map()}.
set_max_thinking_tokens(Session, MaxTokens) when is_integer(MaxTokens), MaxTokens > 0 ->
    SessionId = get_session_id(Session),
    agent_wire_control:set_max_thinking_tokens(SessionId, MaxTokens),
    {ok, #{max_thinking_tokens => MaxTokens}}.

-doc "Revert file changes to a checkpoint via universal checkpointing.".
-spec rewind_files(pid(), binary()) -> ok | {error, not_found | term()}.
rewind_files(Session, CheckpointUuid) ->
    SessionId = get_session_id(Session),
    agent_wire_checkpoint:rewind(SessionId, CheckpointUuid).

-doc "Stop a running agent task via universal task tracking.".
-spec stop_task(pid(), binary()) -> ok | {error, not_found}.
stop_task(Session, TaskId) ->
    SessionId = get_session_id(Session),
    agent_wire_control:stop_task(SessionId, TaskId).

-doc "Run a command via universal command execution.".
-spec command_run(pid(), binary()) ->
    {ok, agent_wire_command:command_result()} | {error, term()}.
command_run(Session, Command) ->
    command_run(Session, Command, #{}).

-doc "Run a command with options via universal command execution.".
-spec command_run(pid(), binary(), map()) ->
    {ok, agent_wire_command:command_result()} | {error, term()}.
command_run(Session, Command, Opts) ->
    SessionId = get_session_id(Session),
    CmdOpts = case agent_wire_session_store:get_session(SessionId) of
        {ok, #{cwd := Cwd}} -> maps:merge(#{cwd => Cwd}, Opts);
        _ -> Opts
    end,
    agent_wire_command:run(Command, CmdOpts).

-doc "Submit feedback via universal feedback tracking.".
-spec submit_feedback(pid(), map()) -> ok.
submit_feedback(Session, Feedback) ->
    SessionId = get_session_id(Session),
    agent_wire_control:submit_feedback(SessionId, Feedback).

-doc "Respond to an agent request via universal turn response.".
-spec turn_respond(pid(), binary(), map()) ->
    ok | {error, not_found | already_resolved}.
turn_respond(Session, RequestId, Params) ->
    SessionId = get_session_id(Session),
    agent_wire_control:resolve_pending_request(SessionId, RequestId, Params).

-doc "Check server health. Maps to session health for Copilot.".
-spec server_health(pid()) -> {ok, map()}.
server_health(Session) ->
    Health = health(Session),
    {ok, #{health => Health, adapter => copilot}}.

%%====================================================================
%% Internal
%%====================================================================

%% Send a query through the behaviour API.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    copilot_session:send_query(Session, Prompt, Params, Timeout).

%% Collect messages until result/error using deadline-based timeout.
-spec collect_messages(pid(), reference(), timeout(), [agent_wire:message()]) ->
    {ok, [agent_wire:message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, Acc) ->
    collect_loop(Session, Ref, Deadline, Acc).

-spec collect_loop(pid(), reference(), integer(), [agent_wire:message()]) ->
    {ok, [agent_wire:message()]} | {error, term()}.
collect_loop(Session, Ref, Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, Deadline - Now),
    case receive_message_from(Session, Ref, Remaining) of
        {ok, #{type := result} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, #{type := error, is_error := true} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, Msg} ->
            collect_loop(Session, Ref, Deadline, [Msg | Acc]);
        {error, timeout} ->
            {error, {timeout, lists:reverse(Acc)}};
        {error, _} = Err ->
            Err
    end.

%% Pull the next message from the session.
-spec receive_message_from(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    copilot_session:receive_message(Session, Ref, Timeout).

-doc "Get session ID from the session process.".
-spec get_session_id(pid()) -> binary().
get_session_id(Session) ->
    case session_info(Session) of
        {ok, #{session_id := SId}} -> SId;
        _ -> unicode:characters_to_binary(erlang:pid_to_list(Session))
    end.

%% Extract a field from session init data.
-spec extract_init_field(pid(), atom(), atom(), term()) ->
    {ok, term()} | {error, term()}.
extract_init_field(Session, IRKey, SIKey, Default) ->
    case session_info(Session) of
        {ok, Info} ->
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
