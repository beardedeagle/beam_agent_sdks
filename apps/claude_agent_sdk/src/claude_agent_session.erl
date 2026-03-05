%%%-------------------------------------------------------------------
%%% @doc Claude Code wire protocol adapter — single gen_statem per session.
%%%
%%% Implements the flattened process topology from the HLD: one process
%%% owns the Erlang Port, manages request serialization, and dispatches
%%% messages to consumers. This eliminates the double-GenServer-hop
%%% anti-pattern found in guess/claude_code.
%%%
%%% Wire protocol: JSONL over stdout/stdin.
%%% CLI invocation: claude --output-format stream-json --input-format stream-json
%%% Bidirectional: stdin for queries/control, stdout for responses/events.
%%%
%%% State machine:
%%%   connecting -> initializing -> ready -> active_query -> ready -> ...
%%%                                            |
%%%                                            +-> error -> (terminate)
%%%
%%% Cross-referenced against TypeScript Agent SDK v0.2.66 for protocol
%%% fidelity. Supports:
%%%   - Rich system init parsing and session capabilities query
%%%   - Session resumption and forking
%%%   - System prompt presets with append
%%%   - Permission handler callback with input modification
%%%   - Runtime control (set_model, set_permission_mode, rewind_files)
%%%   - All 17+ control request subtypes
%%%   - Subagent, MCP, plugin, hooks option passing
%%%   - Structured output, thinking, file checkpointing configuration
%%%
%%% Process count per local session: 2 (this gen_statem + Erlang Port).
%%% @end
%%%-------------------------------------------------------------------
-module(claude_agent_session).

-behaviour(gen_statem).
-behaviour(agent_wire_behaviour).

%% agent_wire_behaviour API
-export([
    start_link/1,
    send_query/4,
    receive_message/3,
    health/1,
    stop/1
]).

%% Optional behaviour callbacks
-export([
    send_control/3,
    interrupt/1,
    session_info/1,
    set_model/2,
    set_permission_mode/2
]).

%% Additional API
-export([
    cancel/2,
    rewind_files/2,
    stop_task/2,
    set_max_thinking_tokens/2,
    mcp_server_status/1,
    set_mcp_servers/2,
    reconnect_mcp_server/2,
    toggle_mcp_server/3
]).

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    terminate/3
]).

%% State functions
-export([
    connecting/3,
    initializing/3,
    ready/3,
    active_query/3,
    error/3
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type state_name() :: connecting | initializing | ready | active_query | error.

%% Union return type for state functions that handle both state_enter
%% and regular events (since we use [state_functions, state_enter]).
-type state_callback_result() ::
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).

-export_type([state_name/0]).

%% Internal helpers where the declared spec is intentionally broader
%% than the implementation (string() vs byte(), map() vs exact keys).
-dialyzer({no_underspecs, [
    resume_args/1,
    permission_mode_args/1,
    tool_args/1,
    debug_args/1,
    build_session_info/1,
    encode_system_prompt/1,
    encode_permission_mode/1,
    write_mcp_config/1
]}).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(data, {
    port               :: port() | undefined,
    buffer = <<>>      :: binary(),
    buffer_max         :: pos_integer(),
    pending = #{}      :: #{binary() => gen_statem:from()},
    consumer           :: gen_statem:from() | undefined,
    query_ref          :: reference() | undefined,
    session_id         :: binary() | undefined,
    opts               :: map(),
    cli_path           :: string(),
    %% Rich session data (from system init message + initialize response)
    system_info = #{}  :: map(),
    init_response = #{} :: map(),
    %% Permission handler callback (Dependency Inversion)
    permission_handler :: fun((binary(), map(), map()) ->
                             agent_wire:permission_result()) | undefined,
    %% User input handler for elicitation control requests
    user_input_handler :: fun((map(), map()) ->
                             {ok, binary()} | {error, term()}) | undefined,
    %% SDK MCP server registry (in-process tool handlers)
    sdk_mcp_registry   :: agent_wire_mcp:mcp_registry() | undefined,
    %% SDK-level lifecycle hook registry (in-process callbacks)
    sdk_hook_registry  :: agent_wire_hooks:hook_registry() | undefined,
    %% Temp file path for MCP config (cleaned up in terminate)
    mcp_config_path    :: string() | undefined,
    %% Query span telemetry (monotonic start time)
    query_start_time   :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% Defaults
%%--------------------------------------------------------------------

-define(DEFAULT_BUFFER_MAX, 2 * 1024 * 1024).  %% 2MB
-define(CONNECT_TIMEOUT, 1000).
-define(INIT_TIMEOUT, 15000).
-define(DEFAULT_CLI, "claude").
-define(SDK_VERSION, "0.1.0").
%% Auto-stop timer for error state — prevents zombie processes.
%% 60 seconds gives diagnostics time while ensuring cleanup.
-define(ERROR_STATE_TIMEOUT, 60000).

%%====================================================================
%% agent_wire_behaviour API
%%====================================================================

%% @doc Start a Claude Code session.
%%
%% Accepts all options defined in agent_wire:session_opts(), including:
%%   cli_path, work_dir, env, buffer_max, session_id, model,
%%   system_prompt (binary or #{type => preset, preset => ...}),
%%   max_turns, resume, fork_session, permission_mode,
%%   permission_handler, allowed_tools, disallowed_tools,
%%   agents, mcp_servers, output_format, thinking, effort,
%%   max_budget_usd, enable_file_checkpointing, setting_sources,
%%   plugins, hooks, betas, include_partial_messages, sandbox,
%%   debug, extra_args, client_app
-spec start_link(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Send a query to the Claude session. Returns a reference for
%%      use with receive_message/3. Only valid when session is in
%%      `ready' state.
-spec send_query(pid(), binary(), agent_wire:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

%% @doc Pull the next message from an active query. Implements
%%      demand-driven backpressure: the gen_statem only parses the
%%      next JSONL line when this function is called.
-spec receive_message(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

%% @doc Get the current health/state of the session.
-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).

%% @doc Gracefully stop the session, closing the CLI subprocess.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).

%% @doc Send a control protocol message (e.g., for session management).
%%      Uses the control_request/control_response protocol.
%%      Works in both ready and active_query states.
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 10000).

%% @doc Interrupt a running query.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).

%% @doc Query session capabilities and initialization data.
%%      Returns system_info (from init message), init_response,
%%      session_id, and session opts.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).

%% @doc Change the model at runtime. Sends a set_model control request.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    send_control(Pid, <<"set_model">>, #{<<"model">> => Model}).

%% @doc Change the permission mode at runtime.
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    send_control(Pid, <<"set_permission_mode">>,
                 #{<<"permissionMode">> => Mode}).

%% @doc Cancel an active query, discarding any buffered messages.
-spec cancel(pid(), reference()) -> ok.
cancel(Pid, Ref) ->
    gen_statem:call(Pid, {cancel, Ref}, 5000).

%% @doc Revert file changes to a checkpoint (identified by user message UUID).
%%      Only meaningful when file checkpointing is enabled.
-spec rewind_files(pid(), binary()) -> {ok, term()} | {error, term()}.
rewind_files(Pid, CheckpointUuid) ->
    send_control(Pid, <<"rewind_files">>,
                 #{<<"checkpoint_uuid">> => CheckpointUuid}).

%% @doc Stop a running agent task by task ID.
-spec stop_task(pid(), binary()) -> {ok, term()} | {error, term()}.
stop_task(Pid, TaskId) ->
    send_control(Pid, <<"stop_task">>, #{<<"task_id">> => TaskId}).

%% @doc Set the maximum thinking tokens at runtime.
-spec set_max_thinking_tokens(pid(), pos_integer()) ->
    {ok, term()} | {error, term()}.
set_max_thinking_tokens(Pid, MaxTokens) when is_integer(MaxTokens),
                                             MaxTokens > 0 ->
    send_control(Pid, <<"set_max_thinking_tokens">>,
                 #{<<"maxThinkingTokens">> => MaxTokens}).

%% @doc Query MCP server health and status.
-spec mcp_server_status(pid()) -> {ok, term()} | {error, term()}.
mcp_server_status(Pid) ->
    send_control(Pid, <<"mcp_status">>, #{}).

%% @doc Dynamically add or replace MCP server configurations.
%%      Accepts a map of server name => config, matching the TS SDK's
%%      setMcpServers() interface.
-spec set_mcp_servers(pid(), map()) -> {ok, term()} | {error, term()}.
set_mcp_servers(Pid, Servers) when is_map(Servers) ->
    send_control(Pid, <<"mcp_set_servers">>,
                 #{<<"servers">> => Servers}).

%% @doc Reconnect a failed MCP server by name.
-spec reconnect_mcp_server(pid(), binary()) -> {ok, term()} | {error, term()}.
reconnect_mcp_server(Pid, ServerName) when is_binary(ServerName) ->
    send_control(Pid, <<"mcp_reconnect">>,
                 #{<<"serverName">> => ServerName}).

%% @doc Enable or disable an MCP server at runtime.
-spec toggle_mcp_server(pid(), binary(), boolean()) ->
    {ok, term()} | {error, term()}.
toggle_mcp_server(Pid, ServerName, Enabled)
  when is_binary(ServerName), is_boolean(Enabled) ->
    send_control(Pid, <<"mcp_toggle">>,
                 #{<<"serverName">> => ServerName,
                   <<"enabled">> => Enabled}).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(connecting) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = resolve_cli_path(maps:get(cli_path, Opts, ?DEFAULT_CLI)),
    BufferMax = maps:get(buffer_max, Opts, ?DEFAULT_BUFFER_MAX),
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    McpRegistry = build_mcp_registry(
        maps:get(sdk_mcp_servers, Opts, undefined)),
    HookRegistry = build_hook_registry(
        maps:get(sdk_hooks, Opts, undefined)),
    McpConfigPath = write_mcp_config(McpRegistry),
    Args = build_cli_args(Opts, McpConfigPath),
    PortOpts = build_port_opts(Opts, Args),
    try
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        Data = #data{
            port = Port,
            buffer_max = BufferMax,
            opts = Opts,
            cli_path = CliPath,
            session_id = maps:get(session_id, Opts, undefined),
            permission_handler = PermHandler,
            user_input_handler = UserInputHandler,
            sdk_mcp_registry = McpRegistry,
            sdk_hook_registry = HookRegistry,
            mcp_config_path = McpConfigPath
        },
        {ok, connecting, Data}
    catch
        error:Reason ->
            cleanup_mcp_config(McpConfigPath),
            logger:warning("Claude session failed to open port: ~p", [Reason]),
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = undefined} = Data) ->
    _ = fire_hook(session_end, #{
        session_id => Data#data.session_id,
        reason => Reason
    }, Data),
    cleanup_mcp_config(Data#data.mcp_config_path),
    ok;
terminate(Reason, _State, #data{port = Port} = Data) ->
    _ = fire_hook(session_end, #{
        session_id => Data#data.session_id,
        reason => Reason
    }, Data),
    catch port_close(Port),
    cleanup_mcp_config(Data#data.mcp_config_path),
    ok.

%%====================================================================
%% State: connecting
%%====================================================================

-spec connecting(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
connecting(enter, _OldState, _Data) ->
    agent_wire_telemetry:state_change(claude, undefined, connecting),
    {keep_state_and_data,
     [{state_timeout, ?CONNECT_TIMEOUT, connect_timeout}]};

connecting(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    Buffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    {next_state, initializing, Data#data{buffer = Buffer}};

connecting(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {cli_exit, Status}}]};

connecting(state_timeout, connect_timeout, Data) ->
    {next_state, initializing, Data};

connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};

connecting({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};

connecting({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, connecting}}]}.

%%====================================================================
%% State: initializing
%%====================================================================

-spec initializing(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
initializing(enter, _OldState, Data) ->
    agent_wire_telemetry:state_change(claude, connecting, initializing),
    ReqId = agent_wire:make_request_id(),
    InitRequest = build_init_request(Data#data.opts, Data#data.sdk_mcp_registry),
    InitMsg = #{
        <<"type">> => <<"control_request">>,
        <<"request_id">> => ReqId,
        <<"request">> => InitRequest
    },
    port_command(Data#data.port, agent_wire_jsonl:encode_line(InitMsg)),
    {keep_state, Data,
     [{state_timeout, 0, check_init_buffer}]};

initializing(state_timeout, check_init_buffer, Data) ->
    case try_extract_init_response(Data#data.buffer, Data) of
        {ok, SessionId, Remaining, Data2} ->
            {next_state, ready,
             Data2#data{buffer = Remaining, session_id = SessionId}};
        {not_ready, _, _Data2} ->
            {keep_state_and_data,
             [{state_timeout, ?INIT_TIMEOUT, init_timeout}]}
    end;

initializing(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    case try_extract_init_response(NewBuffer, Data) of
        {ok, SessionId, Remaining, Data2} ->
            {next_state, ready,
             Data2#data{buffer = Remaining, session_id = SessionId}};
        {not_ready, Buffer2, Data2} ->
            check_buffer_overflow(Data2#data{buffer = Buffer2})
    end;

initializing(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {cli_exit_during_init, Status}}]};

initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {timeout, initializing}}]};

initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};

initializing({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};

initializing({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, initializing}}]}.

%%====================================================================
%% State: ready
%%====================================================================

-spec ready(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
ready(enter, initializing, Data) ->
    agent_wire_telemetry:state_change(claude, initializing, ready),
    _ = fire_hook(session_start, #{
        session_id => Data#data.session_id,
        system_info => Data#data.system_info
    }, Data),
    {keep_state, Data#data{consumer = undefined, query_ref = undefined}};
ready(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(claude, OldState, ready),
    {keep_state, Data#data{consumer = undefined, query_ref = undefined}};

ready({call, From}, {send_query, Prompt, Params}, Data) ->
    case fire_hook(user_prompt_submit, #{
        prompt => Prompt,
        params => Params,
        session_id => Data#data.session_id
    }, Data) of
        ok ->
            Ref = make_ref(),
            QueryMsg = build_query_message(Prompt, Params),
            port_command(Data#data.port, agent_wire_jsonl:encode_line(QueryMsg)),
            StartTime = agent_wire_telemetry:span_start(
                claude, query, #{prompt => Prompt}),
            {next_state, active_query,
             Data#data{query_ref = Ref, buffer = Data#data.buffer,
                        query_start_time = StartTime},
             [{reply, From, {ok, Ref}}]};
        {deny, Reason} ->
            {keep_state_and_data,
             [{reply, From, {error, {hook_denied, Reason}}}]}
    end;

ready({call, From}, {send_control, Method, Params}, Data) ->
    send_control_impl(From, Method, Params, Data);

ready(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    {KeepData, Actions} = process_control_messages(
        Data#data{buffer = NewBuffer}),
    {keep_state, KeepData, Actions};

ready(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {cli_exit, Status}}]};

ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};

ready({call, From}, {receive_message, _Ref}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};

ready({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_supported_in_ready}}]}.

%%====================================================================
%% State: active_query
%%====================================================================

-spec active_query(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
active_query(enter, ready, Data) ->
    agent_wire_telemetry:state_change(claude, ready, active_query),
    {keep_state, Data};

active_query({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    case try_extract_next_deliverable(Data) of
        {ok, Msg, Data2} ->
            case maps:get(type, Msg) of
                result ->
                    _ = fire_hook(stop, #{
                        content => maps:get(content, Msg, <<>>),
                        stop_reason => maps:get(stop_reason, Msg, undefined),
                        duration_ms => maps:get(duration_ms, Msg, undefined),
                        session_id => Data2#data.session_id
                    }, Data2),
                    {next_state, ready, Data2,
                     [{reply, From, {ok, Msg}}]};
                tool_result ->
                    _ = fire_hook(post_tool_use, #{
                        tool_name => maps:get(tool_name, Msg, <<>>),
                        content => maps:get(content, Msg, <<>>),
                        session_id => Data2#data.session_id
                    }, Data2),
                    {keep_state, Data2,
                     [{reply, From, {ok, Msg}}]};
                error ->
                    {next_state, ready, Data2,
                     [{reply, From, {ok, Msg}}]};
                _Other ->
                    {keep_state, Data2,
                     [{reply, From, {ok, Msg}}]}
            end;
        {none, Data2} ->
            {keep_state, Data2#data{consumer = From}}
    end;

active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_query(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    Data2 = Data#data{buffer = NewBuffer},
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            agent_wire_telemetry:buffer_overflow(
                byte_size(NewBuffer), Data#data.buffer_max),
            Actions = case Data#data.consumer of
                undefined -> [];
                Consumer ->
                    [{reply, Consumer, {error, buffer_overflow}}]
            end,
            {next_state, error,
             Data2#data{consumer = undefined},
             [{next_event, internal, buffer_overflow} | Actions]};
        false ->
            maybe_deliver_to_consumer(Data2)
    end;

active_query(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    maybe_span_exception(Data, {cli_exit, Status}),
    Actions = case Data#data.consumer of
        undefined -> [];
        Consumer -> [{reply, Consumer, {error, {cli_exit, Status}}}]
    end,
    {next_state, error, Data#data{port = undefined, consumer = undefined,
                                    query_start_time = undefined},
     [{next_event, internal, {cli_exit, Status}} | Actions]};

active_query({call, From}, {send_control, Method, Params}, Data) ->
    %% Control requests valid during active query (set_model, rewind_files, etc.)
    send_control_impl(From, Method, Params, Data);

active_query({call, From}, interrupt, #data{port = Port} = Data) ->
    send_sigint(Port),
    Actions = case Data#data.consumer of
        undefined -> [{reply, From, ok}];
        Consumer ->
            [{reply, Consumer, {error, interrupted}},
             {reply, From, ok}]
    end,
    {next_state, ready, Data#data{consumer = undefined}, Actions};

active_query({call, From}, {cancel, Ref}, #data{query_ref = Ref} = Data) ->
    Actions = case Data#data.consumer of
        undefined -> [{reply, From, ok}];
        Consumer ->
            [{reply, Consumer, {error, cancelled}},
             {reply, From, ok}]
    end,
    {next_state, ready, Data#data{consumer = undefined}, Actions};

active_query({call, From}, {cancel, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};

active_query({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};

active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

active_query({call, From}, _Request, _Data) ->
    {keep_state_and_data,
     [{reply, From, {error, not_supported_during_query}}]}.

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
error(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(claude, OldState, error),
    case Data#data.port of
        undefined -> ok;
        Port -> catch port_close(Port)
    end,
    maps:foreach(fun(_Id, From) ->
        gen_statem:reply(From, {error, session_error})
    end, Data#data.pending),
    {keep_state, Data#data{port = undefined, pending = #{}},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

error(state_timeout, auto_stop, _Data) ->
    {stop, {shutdown, session_error}};

error(internal, Reason, _Data) ->
    logger:error("claude_agent_session error: ~p", [Reason]),
    keep_state_and_data;

error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};

error({call, From}, session_info, Data) ->
    {keep_state_and_data,
     [{reply, From, {ok, build_session_info(Data)}}]};

error({call, From}, _Request, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

%%====================================================================
%% Internal: CLI Setup
%%====================================================================

-spec resolve_cli_path(file:filename_all()) -> string().
resolve_cli_path(Path) when is_binary(Path) -> binary_to_list(Path);
resolve_cli_path(Path) when is_list(Path)   -> Path;
resolve_cli_path(Path) when is_atom(Path)   -> atom_to_list(Path).

%% @doc Build CLI arguments from session options.
%%      Only spawn-time options go here; protocol-level options go
%%      in the initialize control_request (see build_init_request/1).
%%      McpConfigPath is the pre-written temp file path (or undefined).
-spec build_cli_args(map(), string() | undefined) -> [string()].
build_cli_args(Opts, McpConfigPath) ->
    Base = [
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose"
    ],
    lists:append([
        Base,
        session_id_args(Opts),
        resume_args(Opts),
        model_args(Opts),
        system_prompt_args(Opts),
        max_turns_args(Opts),
        permission_mode_args(Opts),
        tool_args(Opts),
        budget_args(Opts),
        debug_args(Opts),
        extra_args(Opts),
        sdk_mcp_args(McpConfigPath)
    ]).

-spec session_id_args(map()) -> [string()].
session_id_args(Opts) ->
    case maps:get(session_id, Opts, undefined) of
        undefined -> [];
        Id when is_binary(Id) -> ["--session-id", binary_to_list(Id)];
        Id when is_list(Id) -> ["--session-id", Id]
    end.

-spec resume_args(map()) -> [string()].
resume_args(Opts) ->
    R = case maps:get(resume, Opts, false) of
        true -> ["--resume"];
        false -> []
    end,
    C = case maps:get(continue, Opts, false) of
        true -> ["--continue"];
        false -> []
    end,
    R ++ C.

-spec model_args(map()) -> [string()].
model_args(Opts) ->
    case maps:get(model, Opts, undefined) of
        undefined -> [];
        Model when is_binary(Model) -> ["--model", binary_to_list(Model)];
        Model when is_list(Model) -> ["--model", Model]
    end.

-spec system_prompt_args(map()) -> [string()].
system_prompt_args(Opts) ->
    case maps:get(system_prompt, Opts, undefined) of
        undefined -> [];
        #{type := preset} -> [];  %% Preset handled in init request
        SP when is_binary(SP) -> ["--system-prompt", binary_to_list(SP)];
        SP when is_list(SP) -> ["--system-prompt", SP]
    end.

-spec max_turns_args(map()) -> [string()].
max_turns_args(Opts) ->
    case maps:get(max_turns, Opts, undefined) of
        undefined -> [];
        MT when is_integer(MT) -> ["--max-turns", integer_to_list(MT)]
    end.

-spec permission_mode_args(map()) -> [string()].
permission_mode_args(Opts) ->
    case maps:get(permission_mode, Opts, undefined) of
        undefined -> [];
        PM when is_atom(PM) ->
            ["--permission-mode",
             binary_to_list(encode_permission_mode(PM))];
        PM when is_binary(PM) ->
            ["--permission-mode", binary_to_list(PM)]
    end.

-spec tool_args(map()) -> [string()].
tool_args(Opts) ->
    AT = case maps:get(allowed_tools, Opts, undefined) of
        undefined -> [];
        Tools when is_list(Tools) ->
            ["--allowedTools", binary_to_list(iolist_to_binary(json:encode(Tools)))]
    end,
    DT = case maps:get(disallowed_tools, Opts, undefined) of
        undefined -> [];
        DTools when is_list(DTools) ->
            ["--disallowedTools", binary_to_list(iolist_to_binary(json:encode(DTools)))]
    end,
    AT ++ DT.

-spec budget_args(map()) -> [string()].
budget_args(Opts) ->
    case maps:get(max_budget_usd, Opts, undefined) of
        undefined -> [];
        Budget when is_number(Budget) ->
            ["--max-budget-usd", float_to_list(Budget * 1.0, [{decimals, 4}])]
    end.

-spec debug_args(map()) -> [string()].
debug_args(Opts) ->
    D = case maps:get(debug, Opts, false) of
        true -> ["--debug"];
        false -> []
    end,
    DF = case maps:get(debug_file, Opts, undefined) of
        undefined -> [];
        File when is_binary(File) -> ["--debug-file", binary_to_list(File)]
    end,
    D ++ DF.

-spec extra_args(map()) -> [string()].
extra_args(Opts) ->
    case maps:get(extra_args, Opts, undefined) of
        undefined -> [];
        ExtraMap when is_map(ExtraMap) ->
            maps:fold(fun
                (Key, null, Acc) ->
                    %% null value = flag without argument
                    [binary_to_list(iolist_to_binary(["--", Key])) | Acc];
                (Key, Val, Acc) ->
                    [binary_to_list(iolist_to_binary(["--", Key])),
                     binary_to_list(Val) | Acc]
            end, [], ExtraMap)
    end.

%% @doc Return --mcp-config CLI args if a config file was written.
-spec sdk_mcp_args(nonempty_string() | undefined) -> [nonempty_string()].
sdk_mcp_args(undefined) -> [];
sdk_mcp_args(Path) when is_list(Path) -> ["--mcp-config", Path].

%% @doc Build an MCP registry from a list of sdk_mcp_server() definitions.
-spec build_mcp_registry([agent_wire_mcp:sdk_mcp_server()] | undefined) ->
    agent_wire_mcp:mcp_registry() | undefined.
build_mcp_registry(Servers) ->
    agent_wire_mcp:build_registry(Servers).

%% @doc Build the hook registry from a list of hook definitions.
-spec build_hook_registry([agent_wire_hooks:hook_def()] | undefined) ->
    agent_wire_hooks:hook_registry() | undefined.
build_hook_registry(Hooks) ->
    agent_wire_hooks:build_registry(Hooks).

%% @doc Fire an SDK lifecycle hook. Adds the event key to context.
-spec fire_hook(agent_wire_hooks:hook_event(), map(), #data{}) ->
    ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Reg}) ->
    agent_wire_hooks:fire(Event, Context#{event => Event}, Reg).

%% @doc Write the MCP config JSON to a temp file for CLI --mcp-config.
%%      Returns the file path or undefined if no MCP servers configured.
-spec write_mcp_config(agent_wire_mcp:mcp_registry() | undefined) ->
    string() | undefined.
write_mcp_config(undefined) -> undefined;
write_mcp_config(Registry) when map_size(Registry) =:= 0 -> undefined;
write_mcp_config(Registry) ->
    ConfigMap = agent_wire_mcp:servers_for_cli(Registry),
    TmpPath = "/tmp/beam_sdk_mcp_" ++
        integer_to_list(erlang:unique_integer([positive])) ++
        ".json",
    JsonBin = iolist_to_binary(json:encode(ConfigMap)),
    ok = file:write_file(TmpPath, JsonBin),
    TmpPath.

%% @doc Clean up the MCP config temp file if one was created.
-spec cleanup_mcp_config(string() | undefined) -> ok.
cleanup_mcp_config(undefined) -> ok;
cleanup_mcp_config(Path) when is_list(Path) ->
    _ = file:delete(Path),
    ok.

%% @doc Send SIGINT to the CLI subprocess via its OS pid.
%%      Matches TS SDK's process.kill('SIGINT') behavior.
-spec send_sigint(port()) -> ok.
send_sigint(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} ->
            _ = os:cmd("kill -INT " ++ integer_to_list(OsPid)),
            ok;
        undefined ->
            ok
    end.

-dialyzer({nowarn_function, build_port_opts/2}).
-spec build_port_opts(map(), [string(), ...]) -> [atom() | tuple(), ...].
build_port_opts(Opts, Args) ->
    Base = [
        {args, Args},
        binary,
        exit_status,
        use_stdio,
        stderr_to_stdout
    ],
    WorkDirOpt = case maps:get(work_dir, Opts, undefined) of
        undefined -> [];
        Dir when is_binary(Dir) -> [{cd, binary_to_list(Dir)}];
        Dir when is_list(Dir) -> [{cd, Dir}]
    end,
    SdkEnv = [
        {"CLAUDE_CODE_ENTRYPOINT", "sdk-erl"},
        {"CLAUDE_AGENT_SDK_VERSION", ?SDK_VERSION}
    ],
    ClientAppEnv = case maps:get(client_app, Opts, undefined) of
        undefined -> [];
        App when is_binary(App) ->
            [{"CLAUDE_AGENT_SDK_CLIENT_APP", binary_to_list(App)}]
    end,
    UserEnv = maps:get(env, Opts, []),
    EnvOpt = [{env, SdkEnv ++ ClientAppEnv ++ UserEnv}],
    Base ++ WorkDirOpt ++ EnvOpt.

%%====================================================================
%% Internal: Protocol Messages
%%====================================================================

%% @doc Build the initialize control_request with all protocol-level
%%      configuration options. CLI-flag options are handled separately
%%      in build_cli_args/1.
-spec build_init_request(map(), agent_wire_mcp:mcp_registry() | undefined) ->
    map().
build_init_request(Opts, McpRegistry) ->
    Base = #{
        <<"subtype">> => <<"initialize">>,
        <<"hooks">> => encode_value(maps:get(hooks, Opts, #{})),
        <<"agents">> => encode_value(maps:get(agents, Opts, #{}))
    },
    %% Add optional protocol-level configuration
    Additions = [
        {output_format, <<"outputFormat">>},
        {mcp_servers, <<"mcpServers">>},
        {plugins, <<"plugins">>},
        {setting_sources, <<"settingSources">>},
        {thinking, <<"thinking">>},
        {sandbox, <<"sandbox">>},
        {betas, <<"betas">>},
        {effort, <<"effort">>},
        {enable_file_checkpointing, <<"enableFileCheckpointing">>},
        {prompt_suggestions, <<"promptSuggestions">>},
        {include_partial_messages, <<"includePartialMessages">>},
        {persist_session, <<"persistSession">>}
    ],
    M1 = lists:foldl(fun({OptKey, WireKey}, Acc) ->
        case maps:get(OptKey, Opts, undefined) of
            undefined -> Acc;
            Value -> Acc#{WireKey => encode_value(Value)}
        end
    end, Base, Additions),
    %% Add SDK MCP server names for in-process tool dispatch
    %% Uses the pre-built registry (no rebuild)
    M2 = case McpRegistry of
        undefined -> M1;
        Reg when is_map(Reg), map_size(Reg) > 0 ->
            Names = agent_wire_mcp:servers_for_init(Reg),
            M1#{<<"sdkMcpServers">> => Names};
        _ -> M1
    end,
    %% Add system prompt preset if configured as map
    case maps:get(system_prompt, Opts, undefined) of
        #{type := preset} = SP ->
            M2#{<<"systemPrompt">> => encode_system_prompt(SP)};
        _ ->
            M2
    end.

%% @doc Build a query message in the corrected protocol format.
-spec build_query_message(binary(), agent_wire:query_opts()) -> map().
build_query_message(Prompt, Params) ->
    Base = #{
        <<"type">> => <<"user">>,
        <<"message">> => #{
            <<"role">> => <<"user">>,
            <<"content">> => Prompt
        }
    },
    maps:fold(fun
        (system_prompt, V, Acc) when is_binary(V) ->
            Acc#{<<"system_prompt">> => V};
        (allowed_tools, V, Acc) -> Acc#{<<"allowedTools">> => V};
        (disallowed_tools, V, Acc) -> Acc#{<<"disallowedTools">> => V};
        (max_tokens, V, Acc)    -> Acc#{<<"maxTokens">> => V};
        (max_turns, V, Acc)     -> Acc#{<<"maxTurns">> => V};
        (model, V, Acc)         -> Acc#{<<"model">> => V};
        (output_format, V, Acc) -> Acc#{<<"outputFormat">> => V};
        (effort, V, Acc)        -> Acc#{<<"effort">> => V};
        (agent, V, Acc)         -> Acc#{<<"agent">> => V};
        (max_budget_usd, V, Acc) -> Acc#{<<"maxBudgetUsd">> => V};
        (_Key, _V, Acc)         -> Acc
    end, Base, Params).

%%====================================================================
%% Internal: Initialization
%%====================================================================

%% @doc Extract the initialization response from the buffer, capturing
%%      the system init message along the way. Threads the #data{}
%%      record to store system_info and init_response.
-spec try_extract_init_response(binary(), #data{}) ->
    {ok, binary() | undefined, binary(), #data{}} |
    {not_ready, binary(), #data{}}.
try_extract_init_response(Buffer, Data) ->
    case agent_wire_jsonl:extract_line(Buffer) of
        none ->
            {not_ready, Buffer, Data};
        {ok, Line, Rest} ->
            case agent_wire_jsonl:decode_line(Line) of
                {ok, #{<<"type">> := <<"system">>} = SysMsg} ->
                    %% Capture system init message metadata
                    Normalized = agent_wire:normalize_message(SysMsg),
                    SysInfo = maps:get(system_info, Normalized,
                                       Data#data.system_info),
                    Data2 = Data#data{system_info = SysInfo},
                    try_extract_init_response(Rest, Data2);
                {ok, #{<<"type">> := <<"control_response">>} = Msg} ->
                    Response = maps:get(<<"response">>, Msg, #{}),
                    case maps:get(<<"subtype">>, Response, undefined) of
                        <<"success">> ->
                            SessionId = maps:get(
                                <<"session_id">>, Response, undefined),
                            Data2 = Data#data{init_response = Response},
                            {ok, SessionId, Rest, Data2};
                        _ ->
                            try_extract_init_response(Rest, Data)
                    end;
                {ok, _OtherMsg} ->
                    try_extract_init_response(Rest, Data);
                {error, _} ->
                    try_extract_init_response(Rest, Data)
            end
    end.

%%====================================================================
%% Internal: Message Extraction
%%====================================================================

-spec try_extract_message(binary()) ->
    {ok, agent_wire:message(), binary()} | none.
try_extract_message(Buffer) ->
    case agent_wire_jsonl:extract_line(Buffer) of
        none ->
            none;
        {ok, Line, Rest} ->
            case agent_wire_jsonl:decode_line(Line) of
                {ok, RawMsg} ->
                    Msg = agent_wire:normalize_message(RawMsg),
                    {ok, Msg, Rest};
                {error, _DecodeErr} ->
                    try_extract_message(Rest)
            end
    end.

%% @doc Extract the next deliverable message, handling control_requests
%%      internally (auto-approve or delegate to permission_handler).
-spec try_extract_next_deliverable(#data{}) ->
    {ok, agent_wire:message(), #data{}} | {none, #data{}}.
try_extract_next_deliverable(Data) ->
    case try_extract_message(Data#data.buffer) of
        {ok, #{type := control_request} = Msg, Remaining} ->
            handle_inbound_control_request(Msg, Data),
            try_extract_next_deliverable(Data#data{buffer = Remaining});
        {ok, #{type := control_response,
               request_id := ReqId} = CtrlResp, Remaining} ->
            %% Control response during query — deliver to pending caller
            case maps:take(ReqId, Data#data.pending) of
                {From, Pending2} ->
                    gen_statem:reply(From, {ok, CtrlResp}),
                    try_extract_next_deliverable(
                        Data#data{buffer = Remaining, pending = Pending2});
                error ->
                    try_extract_next_deliverable(
                        Data#data{buffer = Remaining})
            end;
        {ok, Msg, Remaining} ->
            {ok, Msg, Data#data{buffer = Remaining}};
        none ->
            {none, Data}
    end.

%% @doc Eagerly process control_request and control_response messages
%%      from the buffer without extracting deliverable messages.
%%      Called when no consumer is waiting — we MUST still respond to
%%      control_requests so the CLI doesn't block.
-spec drain_control_requests(#data{}) -> #data{}.
drain_control_requests(Data) ->
    case try_extract_message(Data#data.buffer) of
        {ok, #{type := control_request} = Msg, Remaining} ->
            handle_inbound_control_request(Msg, Data#data{buffer = Remaining}),
            drain_control_requests(Data#data{buffer = Remaining});
        {ok, #{type := control_response,
               request_id := ReqId} = CtrlResp, Remaining} ->
            case maps:take(ReqId, Data#data.pending) of
                {From, Pending2} ->
                    gen_statem:reply(From, {ok, CtrlResp}),
                    drain_control_requests(
                        Data#data{buffer = Remaining, pending = Pending2});
                error ->
                    drain_control_requests(Data#data{buffer = Remaining})
            end;
        {ok, _RegularMsg, _Remaining} ->
            %% Non-control message — leave it in buffer for consumer
            Data;
        none ->
            Data
    end.

-spec maybe_deliver_to_consumer(#data{}) ->
    gen_statem:event_handler_result(active_query | ready).
maybe_deliver_to_consumer(#data{consumer = undefined} = Data) ->
    %% No consumer waiting, but we MUST eagerly process inbound
    %% control_requests — the CLI blocks waiting for our response.
    Data2 = drain_control_requests(Data),
    {keep_state, Data2};
maybe_deliver_to_consumer(#data{consumer = Consumer} = Data) ->
    case try_extract_next_deliverable(Data) of
        {ok, Msg, Data2} ->
            case maps:get(type, Msg) of
                result ->
                    maybe_span_stop(Data2),
                    _ = fire_hook(stop, #{
                        content => maps:get(content, Msg, <<>>),
                        stop_reason => maps:get(stop_reason, Msg, undefined),
                        duration_ms => maps:get(duration_ms, Msg, undefined),
                        session_id => Data2#data.session_id
                    }, Data2),
                    {next_state, ready,
                     Data2#data{consumer = undefined,
                                 query_start_time = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                tool_result ->
                    _ = fire_hook(post_tool_use, #{
                        tool_name => maps:get(tool_name, Msg, <<>>),
                        content => maps:get(content, Msg, <<>>),
                        session_id => Data2#data.session_id
                    }, Data2),
                    {keep_state,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                error ->
                    {next_state, ready,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]};
                _Other ->
                    {keep_state,
                     Data2#data{consumer = undefined},
                     [{reply, Consumer, {ok, Msg}}]}
            end;
        {none, Data2} ->
            {keep_state, Data2}
    end.

-spec check_buffer_overflow(#data{}) ->
    gen_statem:event_handler_result(initializing | error).
check_buffer_overflow(#data{buffer = Buffer, buffer_max = Max} = Data) ->
    case byte_size(Buffer) > Max of
        true ->
            agent_wire_telemetry:buffer_overflow(byte_size(Buffer), Max),
            {next_state, error, Data,
             [{next_event, internal, buffer_overflow}]};
        false ->
            {keep_state, Data}
    end.

%%====================================================================
%% Internal: Control Message Handling
%%====================================================================

%% @doc Shared implementation for sending control requests.
%%      Used by both ready and active_query states.
-spec send_control_impl(gen_statem:from(), binary(), map(), #data{}) ->
    gen_statem:event_handler_result(state_name()).
send_control_impl(From, Method, Params, Data) ->
    ReqId = agent_wire:make_request_id(),
    Request = Params#{<<"subtype">> => Method},
    ControlMsg = #{
        <<"type">> => <<"control_request">>,
        <<"request_id">> => ReqId,
        <<"request">> => Request
    },
    port_command(Data#data.port, agent_wire_jsonl:encode_line(ControlMsg)),
    Pending = maps:put(ReqId, From, Data#data.pending),
    {keep_state, Data#data{pending = Pending}}.

%% @doc Process control responses and inbound requests in ready state.
-spec process_control_messages(#data{}) -> {#data{}, [gen_statem:action()]}.
process_control_messages(Data) ->
    process_control_messages_loop(Data, []).

-spec process_control_messages_loop(#data{}, [gen_statem:action()]) ->
    {#data{}, [gen_statem:action()]}.
process_control_messages_loop(Data, Actions) ->
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            {Data, Actions};
        {ok, Line, Rest} ->
            case agent_wire_jsonl:decode_line(Line) of
                {ok, #{<<"type">> := <<"control_response">>,
                       <<"request_id">> := ReqId} = Msg} ->
                    case maps:take(ReqId, Data#data.pending) of
                        {From, Pending2} ->
                            Data2 = Data#data{buffer = Rest,
                                              pending = Pending2},
                            process_control_messages_loop(
                                Data2, [{reply, From, {ok, Msg}} | Actions]);
                        error ->
                            process_control_messages_loop(
                                Data#data{buffer = Rest}, Actions)
                    end;
                {ok, #{<<"type">> := <<"control_request">>} = RawMsg} ->
                    Msg = agent_wire:normalize_message(RawMsg),
                    handle_inbound_control_request(Msg, Data),
                    process_control_messages_loop(
                        Data#data{buffer = Rest}, Actions);
                _ ->
                    process_control_messages_loop(
                        Data#data{buffer = Rest}, Actions)
            end
    end.

%% @doc Handle an inbound control_request from the CLI.
%%      For can_use_tool: delegates to permission_handler if configured,
%%      otherwise auto-approves. All other subtypes are auto-approved.
-spec handle_inbound_control_request(agent_wire:message(), #data{}) -> ok.
handle_inbound_control_request(Msg, #data{port = Port} = Data) ->
    ReqId = maps:get(request_id, Msg, undefined),
    Request = maps:get(request, Msg, #{}),
    Subtype = maps:get(<<"subtype">>, Request, undefined),
    Response = build_inbound_response(Subtype, Request, Data),
    ResponseMsg = #{
        <<"type">> => <<"control_response">>,
        <<"request_id">> => ReqId,
        <<"response">> => Response
    },
    port_command(Port, agent_wire_jsonl:encode_line(ResponseMsg)),
    ok.

%% @doc Build a response for an inbound control request.
%%      Uses permission_handler for can_use_tool if configured.
-spec build_inbound_response(binary() | undefined, map(), #data{}) -> map().
build_inbound_response(<<"can_use_tool">>, Request,
                       #data{permission_handler = Handler,
                             sdk_hook_registry = HookReg} = Data) ->
    ToolName = maps:get(<<"tool_name">>, Request, <<>>),
    ToolInput = maps:get(<<"tool_input">>, Request, #{}),
    ToolUseId = maps:get(<<"tool_use_id">>, Request, <<>>),
    AgentId = maps:get(<<"agent_id">>, Request, undefined),
    HookCtx = #{
        tool_name => ToolName,
        tool_input => ToolInput,
        tool_use_id => ToolUseId,
        agent_id => AgentId,
        session_id => Data#data.session_id
    },
    case agent_wire_hooks:fire(pre_tool_use, HookCtx#{event => pre_tool_use}, HookReg) of
        {deny, Reason} ->
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => Reason};
        ok when is_function(Handler, 3) ->
            Options = #{tool_use_id => ToolUseId, agent_id => AgentId},
            try Handler(ToolName, ToolInput, Options) of
                {allow, UpdatedInput} ->
                    #{<<"subtype">> => <<"approve">>,
                      <<"updatedInput">> => UpdatedInput};
                {allow, UpdatedInput, RuleUpdate} ->
                    #{<<"subtype">> => <<"approve">>,
                      <<"updatedInput">> => UpdatedInput,
                      <<"ruleUpdate">> => RuleUpdate};
                {deny, Reason} ->
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> => Reason}
            catch
                Class:CrashReason:Stack ->
                    logger:error("permission_handler crashed: ~p:~p~n~p",
                                 [Class, CrashReason, Stack]),
                    %% Fail-closed: deny on crash (security gate)
                    #{<<"subtype">> => <<"deny">>,
                      <<"message">> => <<"Permission handler crashed">>}
            end;
        ok ->
            %% No handler — use permission_default (fail-closed by default)
            case maps:get(permission_default, Data#data.opts, deny) of
                allow -> #{<<"subtype">> => <<"approve">>};
                _     -> #{<<"subtype">> => <<"deny">>,
                           <<"message">> => <<"No permission handler registered">>}
            end
    end;
build_inbound_response(<<"hook_callback">>, _Request, _Data) ->
    #{<<"subtype">> => <<"ok">>};
build_inbound_response(<<"mcp_message">>, Request,
                       #data{sdk_mcp_registry = Registry})
  when is_map(Registry) ->
    ServerName = maps:get(<<"server_name">>, Request, <<>>),
    Message = maps:get(<<"message">>, Request, #{}),
    case agent_wire_mcp:handle_mcp_message(ServerName, Message, Registry) of
        {ok, McpResponse} ->
            #{<<"subtype">> => <<"ok">>,
              <<"mcp_response">> => McpResponse};
        {error, _} ->
            #{<<"subtype">> => <<"ok">>}
    end;
build_inbound_response(<<"mcp_message">>, _Request, _Data) ->
    #{<<"subtype">> => <<"ok">>};
build_inbound_response(<<"elicitation">>, Request,
                       #data{user_input_handler = Handler} = Data)
  when is_function(Handler, 2) ->
    ElicitRequest = #{
        message => maps:get(<<"message">>, Request, <<>>),
        schema => maps:get(<<"schema">>, Request, #{}),
        tool_use_id => maps:get(<<"tool_use_id">>, Request, undefined),
        agent_id => maps:get(<<"agent_id">>, Request, undefined)
    },
    Ctx = #{session_id => Data#data.session_id},
    try Handler(ElicitRequest, Ctx) of
        {ok, Answer} ->
            #{<<"subtype">> => <<"ok">>,
              <<"result">> => Answer};
        {error, Reason} when is_binary(Reason) ->
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => Reason};
        {error, _} ->
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input denied">>}
    catch
        Class:CrashReason:Stack ->
            logger:error("user_input_handler crashed: ~p:~p~n~p",
                         [Class, CrashReason, Stack]),
            %% Fail-closed: deny on crash
            #{<<"subtype">> => <<"deny">>,
              <<"message">> => <<"User input handler crashed">>}
    end;
build_inbound_response(<<"elicitation">>, _Request, _Data) ->
    %% No handler registered — deny (fail-closed)
    #{<<"subtype">> => <<"deny">>,
      <<"message">> => <<"No user input handler registered">>};
build_inbound_response(_, _Request, _Data) ->
    #{<<"subtype">> => <<"ok">>}.

%%====================================================================
%% Internal: Session Info
%%====================================================================

%% @doc Build the session info map returned by session_info/1.
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{
        session_id => Data#data.session_id,
        system_info => Data#data.system_info,
        init_response => Data#data.init_response
    }.

%%====================================================================
%% Internal: Encoding Helpers
%%====================================================================

%% @doc Encode a system prompt preset config for the wire protocol.
-spec encode_system_prompt(map()) -> map().
encode_system_prompt(#{type := preset, preset := Preset} = SP) ->
    Base = #{<<"type">> => <<"preset">>, <<"preset">> => Preset},
    case maps:get(append, SP, undefined) of
        undefined -> Base;
        Append -> Base#{<<"append">> => Append}
    end.

%% @doc Encode a permission mode atom to the wire binary format.
-spec encode_permission_mode(agent_wire:permission_mode()) -> binary().
encode_permission_mode(default)            -> <<"default">>;
encode_permission_mode(accept_edits)       -> <<"acceptEdits">>;
encode_permission_mode(bypass_permissions) -> <<"bypassPermissions">>;
encode_permission_mode(plan)               -> <<"plan">>;
encode_permission_mode(dont_ask)           -> <<"dontAsk">>.

%% @doc Pass-through encoder for option values. Most values encode
%%      directly; atoms get converted to binaries for JSON safety.
-spec encode_value(term()) -> term().
encode_value(V) when is_atom(V), V =/= true, V =/= false, V =/= null ->
    atom_to_binary(V);
encode_value(V) ->
    V.

%%====================================================================
%% Internal: Telemetry Span Helpers
%%====================================================================

-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) -> ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    agent_wire_telemetry:span_stop(claude, query, StartTime).

-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) -> ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    agent_wire_telemetry:span_exception(claude, query, Reason).
