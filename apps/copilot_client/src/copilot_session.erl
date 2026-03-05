%%%-------------------------------------------------------------------
%%% @doc Copilot CLI wire protocol adapter — gen_statem.
%%%
%%% Adapter for `copilot server --stdio` mode. Implements full
%%% bidirectional JSON-RPC 2.0 over Content-Length framed stdio
%%% with the Copilot CLI.
%%%
%%% State machine:
%%%   connecting -> initializing -> ready -> active_query -> ready
%%%                                  |              |
%%%                                  +-> error <----+
%%%
%%% Key characteristics:
%%%   - Standard JSON-RPC 2.0 (with "jsonrpc":"2.0" on wire)
%%%   - Content-Length framing (NOT JSONL — LSP-style framing)
%%%   - Port in `stream` mode (raw bytes, not line-delimited)
%%%   - Server-initiated requests: tool.call, permission.request,
%%%     hooks.invoke, user_input.request
%%%   - Session created via session.create RPC
%%%   - Query via session.send + session.event notifications
%%%   - session.idle event signals query completion
%%%
%%% Implements agent_wire_behaviour for unified consumer API.
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_session).

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
    set_model/2
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

-type state_callback_result() ::
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).

-export_type([state_name/0]).

%% Internal helpers with intentionally broad specs.
-dialyzer({no_underspecs, [
    build_session_info/1,
    build_port_opts/1,
    call_permission_handler/3,
    call_hook_handler/4,
    call_user_input_handler/3
]}).
-dialyzer({nowarn_function, [
    call_permission_handler/3,
    call_hook_handler/4,
    call_user_input_handler/3
]}).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(data, {
    %% Port & buffer
    port               :: port() | undefined,
    buffer = <<>>      :: binary(),
    buffer_max         :: pos_integer(),

    %% JSON-RPC correlation (binary ID → {From | Tag, TimerRef})
    %% Tags: internal (fire-and-forget), internal_create (session.create)
    pending = #{}      :: #{binary() => {gen_statem:from() | internal | internal_create,
                                          reference() | undefined}},
    next_id = 1        :: pos_integer(),

    %% Consumer demand (same pattern as codex_session / claude_agent_session)
    consumer           :: gen_statem:from() | undefined,
    query_ref          :: reference() | undefined,
    msg_queue          :: queue:queue() | undefined,

    %% Session state
    session_id         :: binary() | undefined,
    copilot_session_id :: binary() | undefined,

    %% Configuration
    opts               :: map(),
    cli_path           :: string(),
    model              :: binary() | undefined,

    %% Handler callbacks
    sdk_mcp_registry   :: agent_wire_mcp:mcp_registry() | undefined,
    permission_handler  :: fun() | undefined,
    user_input_handler  :: fun() | undefined,

    %% Shared infrastructure
    sdk_hook_registry  :: agent_wire_hooks:hook_registry() | undefined,
    %% Query span telemetry (monotonic start time)
    query_start_time   :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% Constants
%%--------------------------------------------------------------------

-define(DEFAULT_BUFFER_MAX, 2097152).  %% 2 MB
-define(DEFAULT_TIMEOUT, 120000).      %% 120s query timeout
-define(CONNECT_TIMEOUT, 15000).       %% 15s connect timeout
-define(PING_TIMEOUT, 10000).          %% 10s ping timeout
-define(ERROR_LINGER, 60000).          %% 60s before auto-stop on error

%%====================================================================
%% agent_wire_behaviour API
%%====================================================================

%% @doc Start the Copilot session gen_statem.
-spec start_link(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

%% @doc Send a query to the session. Returns a reference for receive_message/3.
-spec send_query(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

%% @doc Pull the next message from the session's message queue.
-spec receive_message(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

%% @doc Get the current health state.
-spec health(pid()) -> atom().
health(Pid) ->
    gen_statem:call(Pid, health, 5000).

%% @doc Stop the session.
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).

%%====================================================================
%% Optional Behaviour Callbacks
%%====================================================================

%% @doc Send an arbitrary JSON-RPC request to the Copilot CLI.
-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 30000).

%% @doc Abort the current query (sends session.abort).
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 10000).

%% @doc Get session info.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 10000).

%% @doc Change the model for this session.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 10000).

%%====================================================================
%% gen_statem Callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(state_name()).
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = resolve_cli_path(Opts),
    HookRegistry = agent_wire_hooks:build_registry(maps:get(sdk_hooks, Opts, undefined)),
    McpRegistry = build_mcp_registry(Opts),
    %% Inject MCP tool definitions into opts so protocol can advertise them
    %% in session.create (wire format uses sdk_tools key).
    Opts1 = case McpRegistry of
        undefined -> Opts;
        Reg ->
            case agent_wire_mcp:all_tool_definitions(Reg) of
                [] -> Opts;
                ToolDefs -> Opts#{sdk_tools => ToolDefs}
            end
    end,
    PermHandler = maps:get(permission_handler, Opts, undefined),
    UserInputHandler = maps:get(user_input_handler, Opts, undefined),
    Data = #data{
        opts               = Opts1,
        cli_path           = CliPath,
        buffer_max         = maps:get(buffer_max, Opts, ?DEFAULT_BUFFER_MAX),
        model              = maps:get(model, Opts, undefined),
        session_id         = maps:get(session_id, Opts, undefined),
        sdk_mcp_registry   = McpRegistry,
        permission_handler = PermHandler,
        user_input_handler = UserInputHandler,
        sdk_hook_registry  = HookRegistry
    },
    %% Open port in init (like Claude/Codex adapters) so start_link
    %% fails immediately if CLI path is invalid.
    case open_copilot_port(Data) of
        {ok, Port} ->
            {ok, connecting, Data#data{port = Port}};
        {error, Reason} ->
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.

-spec terminate(term(), state_name(), #data{}) -> ok.
terminate(Reason, _State, Data) ->
    _ = fire_hook(session_end, #{event => session_end, reason => Reason}, Data),
    close_port(Data#data.port),
    %% Fail any pending JSON-RPC requests
    maps:foreach(fun(_Id, {From, TRef}) ->
        cancel_timer(TRef),
        case From of
            internal -> ok;
            internal_create -> ok;
            _ -> gen_statem:reply(From, {error, session_terminated})
        end
    end, Data#data.pending),
    %% Fail waiting consumer
    case Data#data.consumer of
        undefined -> ok;
        Consumer -> gen_statem:reply(Consumer, {error, session_terminated})
    end,
    ok.

%%====================================================================
%% State: connecting
%%====================================================================

-spec connecting(gen_statem:event_type(), term(), #data{}) ->
    state_callback_result().

connecting(enter, _OldState, Data) ->
    %% Port already opened in init/1 — send ping to verify server is ready
    agent_wire_telemetry:state_change(copilot, undefined, connecting),
    ReqId = make_request_id(Data),
    PingMsg = copilot_protocol:encode_request(
        ReqId, <<"ping">>, #{<<"message">> => <<"hello">>}),
    port_command(Data#data.port, copilot_frame:encode_message(PingMsg)),
    NewData = Data#data{
        next_id = Data#data.next_id + 1,
        pending = maps:put(ReqId, {internal, undefined},
                           Data#data.pending)
    },
    {keep_state, NewData, [{state_timeout, ?CONNECT_TIMEOUT, connect_timeout}]};

%% Ping response received — server is ready
connecting(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            agent_wire_telemetry:buffer_overflow(
                byte_size(NewBuffer), Data#data.buffer_max),
            {next_state, error, Data#data{buffer = <<>>},
             [{next_event, internal, {connect_error, buffer_overflow}}]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData = NewData0#data{buffer = RestBuf},
                    case handle_connecting_messages(Messages, NewData) of
                        {ping_ok, Data1} ->
                            {next_state, initializing, Data1};
                        {wait, Data1} ->
                            {keep_state, Data1}
                    end
            end
    end;

connecting(state_timeout, connect_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {connect_error, connect_timeout}}]};

connecting(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};

connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};

connecting({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

connecting({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, connecting}}]}.

%%====================================================================
%% State: initializing
%%====================================================================

-spec initializing(gen_statem:event_type(), term(), #data{}) ->
    state_callback_result().

initializing(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(copilot, OldState, initializing),
    %% Create the Copilot session
    ReqId = make_request_id(Data),
    Params = copilot_protocol:build_session_create_params(Data#data.opts),
    Msg = copilot_protocol:encode_request(ReqId, <<"session.create">>, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData = Data#data{
        next_id = Data#data.next_id + 1,
        pending = maps:put(ReqId, {internal_create, undefined}, Data#data.pending)
    },
    {keep_state, NewData, [{state_timeout, ?CONNECT_TIMEOUT, init_timeout}]};

initializing(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    case byte_size(NewBuffer) > Data#data.buffer_max of
        true ->
            agent_wire_telemetry:buffer_overflow(
                byte_size(NewBuffer), Data#data.buffer_max),
            {next_state, error, Data#data{buffer = <<>>},
             [{next_event, internal, {init_error, buffer_overflow}}]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData = NewData0#data{buffer = RestBuf},
                    case handle_init_messages(Messages, NewData) of
                        {session_created, SessionId, Data1} ->
                            _ = fire_hook(session_start, #{session_id => SessionId}, Data1),
                            {next_state, ready, Data1#data{copilot_session_id = SessionId}};
                        {wait, Data1} ->
                            {keep_state, Data1}
                    end
            end
    end;

initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data,
     [{next_event, internal, {init_error, init_timeout}}]};

initializing(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};

initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};

initializing({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, initializing}}]}.

%%====================================================================
%% State: ready
%%====================================================================

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    state_callback_result().

ready(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(copilot, OldState, ready),
    keep_state_and_data;

%% Accept new query
ready({call, From}, {send_query, Prompt, Params}, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            case fire_hook(user_prompt_submit, #{prompt => Prompt}, Data) of
                {deny, _Reason} ->
                    {keep_state_and_data,
                     [{reply, From, {error, denied_by_hook}}]};
                _ ->
                    Ref = make_ref(),
                    StartTime = agent_wire_telemetry:span_start(
                        copilot, query, #{prompt => Prompt}),
                    ReqId = make_request_id(Data),
                    SendParams = copilot_protocol:build_session_send_params(
                        SessionId, Prompt, Params),
                    Msg = copilot_protocol:encode_request(
                        ReqId, <<"session.send">>, SendParams),
                    port_command(Data#data.port,
                                copilot_frame:encode_message(Msg)),
                    NewData = Data#data{
                        query_ref = Ref,
                        msg_queue = queue:new(),
                        next_id = Data#data.next_id + 1,
                        pending = maps:put(ReqId, {internal, undefined},
                                           Data#data.pending),
                        query_start_time = StartTime
                    },
                    {next_state, active_query, NewData,
                     [{reply, From, {ok, Ref}}]}
            end
    end;

ready({call, From}, {receive_message, _Ref}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};

ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

ready({call, From}, {set_model, Model}, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            ReqId = make_request_id(Data),
            Params = #{<<"sessionId">> => SessionId,
                       <<"modelId">> => Model},
            Msg = copilot_protocol:encode_request(
                ReqId, <<"session.model.switchTo">>, Params),
            port_command(Data#data.port, copilot_frame:encode_message(Msg)),
            NewData = Data#data{
                next_id = Data#data.next_id + 1,
                pending = maps:put(ReqId, {From, undefined},
                                   Data#data.pending),
                model = Model
            },
            {keep_state, NewData}
    end;

ready({call, From}, {send_control, Method, Params}, Data) ->
    ReqId = make_request_id(Data),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData = Data#data{
        next_id = Data#data.next_id + 1,
        pending = maps:put(ReqId, {From, undefined}, Data#data.pending)
    },
    {keep_state, NewData};

ready({call, From}, interrupt, _Data) ->
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};

%% Handle port data in ready state (e.g., lifecycle notifications)
ready(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    case process_buffer(NewBuffer, Data) of
        {Messages, RestBuf, NewData0} ->
            NewData1 = NewData0#data{buffer = RestBuf},
            NewData2 = handle_ready_messages(Messages, NewData1),
            {keep_state, NewData2}
    end;

ready(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};

ready(info, {'EXIT', Port, _Reason}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{next_event, internal, {port_exit, abnormal}}]}.

%%====================================================================
%% State: active_query
%%====================================================================

-spec active_query(gen_statem:event_type(), term(), #data{}) ->
    state_callback_result().

active_query(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(copilot, OldState, active_query),
    keep_state_and_data;

%% Reject concurrent queries
active_query({call, From}, {send_query, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

%% Consumer pulls a message
active_query({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    case queue:out(Data#data.msg_queue) of
        {{value, Msg}, NewQueue} ->
            case is_terminal_message(Msg) of
                true ->
                    %% Terminal message (result/error) — transition to ready.
                    %% Any remaining messages in queue are post-result noise.
                    {next_state, ready,
                     Data#data{msg_queue = undefined, consumer = undefined,
                               query_ref = undefined},
                     [{reply, From, {ok, Msg}}]};
                false ->
                    {keep_state, Data#data{msg_queue = NewQueue},
                     [{reply, From, {ok, Msg}}]}
            end;
        {empty, _} ->
            %% Park the consumer — will be replied when a message arrives
            {keep_state, Data#data{consumer = From}}
    end;

active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};

active_query({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

%% Abort the active query
active_query({call, From}, interrupt, Data) ->
    SessionId = Data#data.copilot_session_id,
    case SessionId of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_session}}]};
        _ ->
            ReqId = make_request_id(Data),
            Params = #{<<"sessionId">> => SessionId},
            Msg = copilot_protocol:encode_request(
                ReqId, <<"session.abort">>, Params),
            port_command(Data#data.port, copilot_frame:encode_message(Msg)),
            %% Reply ok immediately — abort response handled internally.
            %% The session.idle event will signal query completion.
            NewData = Data#data{
                next_id = Data#data.next_id + 1,
                pending = maps:put(ReqId, {internal, undefined},
                                   Data#data.pending)
            },
            {keep_state, NewData, [{reply, From, ok}]}
    end;

%% Send control in active_query state
active_query({call, From}, {send_control, Method, Params}, Data) ->
    ReqId = make_request_id(Data),
    Msg = copilot_protocol:encode_request(ReqId, Method, Params),
    port_command(Data#data.port, copilot_frame:encode_message(Msg)),
    NewData = Data#data{
        next_id = Data#data.next_id + 1,
        pending = maps:put(ReqId, {From, undefined}, Data#data.pending)
    },
    {keep_state, NewData};

active_query({call, From}, {set_model, _Model}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

%% Main data handler — process incoming bytes from port
active_query(info, {Port, {data, RawData}}, #data{port = Port} = Data) ->
    NewBuffer = <<(Data#data.buffer)/binary, RawData/binary>>,
    %% Check buffer overflow
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
             Data#data{buffer = <<>>, consumer = undefined},
             [{next_event, internal, buffer_overflow} | Actions]};
        false ->
            case process_buffer(NewBuffer, Data) of
                {Messages, RestBuf, NewData0} ->
                    NewData1 = NewData0#data{buffer = RestBuf},
                    NewData2 = handle_active_messages(Messages, NewData1),
                    %% Check if session.idle was received (query complete)
                    case NewData2#data.msg_queue of
                        undefined ->
                            %% Queue was cleared — transitioned to ready
                            {next_state, ready, NewData2};
                        _ ->
                            {keep_state, NewData2}
                    end
            end
    end;

active_query(info, {Port, {exit_status, Code}}, #data{port = Port} = Data) ->
    %% Port exited during query — synthesize error and transition
    maybe_span_exception(Data, {cli_exit, Code}),
    ErrorMsg = #{type => error,
                 content => iolist_to_binary(
                     io_lib:format("CLI exited with code ~p during query", [Code]))},
    Data1 = deliver_or_enqueue(ErrorMsg, Data#data{query_start_time = undefined}),
    ResultMsg = #{type => result, is_error => true,
                  content => <<"CLI process exited unexpectedly">>},
    Data2 = deliver_or_enqueue(ResultMsg, Data1),
    {next_state, error, Data2#data{port = undefined},
     [{next_event, internal, {port_exit, Code}}]};

active_query(info, {'EXIT', Port, Reason}, #data{port = Port} = Data) ->
    maybe_span_exception(Data, {port_crash, Reason}),
    ErrorMsg = #{type => error, content => <<"CLI process crashed">>},
    Data1 = deliver_or_enqueue(ErrorMsg, Data#data{query_start_time = undefined}),
    {next_state, error, Data1#data{port = undefined},
     [{next_event, internal, {port_exit, abnormal}}]}.

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #data{}) ->
    state_callback_result().

error(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(copilot, OldState, error),
    close_port(Data#data.port),
    %% Fail all pending requests
    maps:foreach(fun(_Id, {From, TRef}) ->
        cancel_timer(TRef),
        case From of
            internal -> ok;
            internal_create -> ok;
            _ -> gen_statem:reply(From, {error, session_error})
        end
    end, Data#data.pending),
    NewData = Data#data{port = undefined, pending = #{}},
    {keep_state, NewData, [{state_timeout, ?ERROR_LINGER, auto_stop}]};

error(internal, Reason, _Data) ->
    logger:error("Copilot session error: ~p", [Reason]),
    keep_state_and_data;

error(state_timeout, auto_stop, _Data) ->
    {stop, {shutdown, error_linger_expired}};

error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};

error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]};

%% Absorb stale port messages (2-tuple: {Port, {data, _}} / {Port, {exit_status, _}})
error(info, {_Port, _}, _Data) ->
    keep_state_and_data;

%% Absorb stale EXIT messages (3-tuple: {'EXIT', Port, Reason})
error(info, {'EXIT', _, _}, _Data) ->
    keep_state_and_data.

%%====================================================================
%% Internal: Port Management
%%====================================================================

%% @private Open the Copilot CLI port.
-spec open_copilot_port(#data{}) -> {ok, port()} | {error, term()}.
open_copilot_port(Data) ->
    CliPath = Data#data.cli_path,
    Args = copilot_protocol:build_cli_args(Data#data.opts),
    Env = copilot_protocol:build_env(Data#data.opts),
    PortOpts = build_port_opts(Data#data.opts),
    try
        Port = open_port(
            {spawn_executable, CliPath},
            [{args, Args}, {env, Env} | PortOpts]
        ),
        {ok, Port}
    catch
        error:Reason -> {error, {open_port_failed, Reason}}
    end.

%% @private Build port options.
-spec build_port_opts(map()) -> list().
build_port_opts(Opts) ->
    Base = [binary, stream, use_stdio, exit_status, hide],
    WorkDir = maps:get(work_dir, Opts,
                maps:get(cwd, Opts, undefined)),
    case WorkDir of
        undefined -> Base;
        Dir when is_binary(Dir) -> [{cd, binary_to_list(Dir)} | Base];
        Dir when is_list(Dir) -> [{cd, Dir} | Base]
    end.

%% @private Resolve CLI path from options.
-spec resolve_cli_path(map()) -> string().
resolve_cli_path(Opts) ->
    case maps:get(cli_path, Opts, undefined) of
        undefined -> "copilot";
        Path when is_binary(Path) -> binary_to_list(Path);
        Path when is_list(Path) -> Path
    end.

%%====================================================================
%% Internal: Buffer Processing
%%====================================================================

%% @private Process the buffer, extracting all complete messages.
%%          Dispatches JSON-RPC responses to pending requests.
%%          Returns {EventMessages, RemainingBuffer, UpdatedData}.
-spec process_buffer(binary(), #data{}) -> {[map()], binary(), #data{}}.
process_buffer(Buffer, Data) ->
    {RawMsgs, RestBuf} = copilot_frame:extract_messages(Buffer),
    {Events, NewData} = dispatch_jsonrpc(RawMsgs, Data, []),
    {Events, RestBuf, NewData}.

%% @private Dispatch JSON-RPC messages: route responses to pending,
%%          handle server-initiated requests, collect notifications.
-spec dispatch_jsonrpc([map()], #data{}, [map()]) -> {[map()], #data{}}.
dispatch_jsonrpc([], Data, Acc) ->
    {lists:reverse(Acc), Data};
dispatch_jsonrpc([Msg | Rest], Data, Acc) ->
    case agent_wire_jsonrpc:decode(Msg) of
        %% Response to our request
        {response, Id, Result} ->
            NewData = handle_response(Id, {ok, Result}, Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        {error_response, Id, Code, ErrMsg, ErrData} ->
            NewData = handle_response(Id, {error, {Code, ErrMsg, ErrData}}, Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        %% Notification from server (session events)
        {notification, <<"session.event">>, Params} ->
            Event = maps:get(<<"event">>, Params, Params),
            dispatch_jsonrpc(Rest, Data, [Event | Acc]);
        {notification, _Method, _Params} ->
            %% Other notifications (lifecycle, etc.) — skip for now
            dispatch_jsonrpc(Rest, Data, Acc);
        %% Server-initiated request (tool.call, permission.request, etc.)
        {request, ReqId, Method, Params} ->
            NewData = handle_server_request(ReqId, Method, Params, Data),
            dispatch_jsonrpc(Rest, NewData, Acc);
        {unknown, _} ->
            dispatch_jsonrpc(Rest, Data, Acc)
    end.

%% @private Handle a JSON-RPC response to one of our pending requests.
-spec handle_response(binary() | integer(), {ok, term()} | {error, term()}, #data{}) -> #data{}.
handle_response(Id, Result, Data) ->
    BinId = ensure_binary_id(Id),
    case maps:take(BinId, Data#data.pending) of
        {{internal, TRef}, NewPending} ->
            cancel_timer(TRef),
            Data#data{pending = NewPending};
        {{internal_create, TRef}, NewPending} ->
            %% session.create response — extract session ID
            cancel_timer(TRef),
            SessionId = case Result of
                {ok, #{<<"sessionId">> := SId}} -> SId;
                {ok, #{<<"session_id">> := SId}} -> SId;
                _ -> undefined
            end,
            Data#data{pending = NewPending,
                      copilot_session_id = SessionId};
        {{From, TRef}, NewPending} ->
            cancel_timer(TRef),
            gen_statem:reply(From, Result),
            Data#data{pending = NewPending};
        error ->
            %% No pending request — stale response, ignore
            Data
    end.

%%====================================================================
%% Internal: Server-Initiated Requests
%%====================================================================

%% @private Handle a request from the Copilot CLI server.
%% Spec is intentionally broader than success typing — the permission.request
%% handler enriches the event map with adapter-specific keys (permission_kind,
%% raw) beyond agent_wire:message(), matching the normalize_message/1 pattern.
-dialyzer({nowarn_function, handle_server_request/4}).
-spec handle_server_request(binary() | integer(), binary(), map() | undefined, #data{}) -> #data{}.

%% tool.call — invoke a custom SDK-registered MCP tool
handle_server_request(ReqId, <<"tool.call">>, Params,
                      #data{sdk_mcp_registry = Registry} = Data)
  when is_map(Registry) ->
    ToolName = maps:get(<<"toolName">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Result = agent_wire_mcp:call_tool_by_name(ToolName, Arguments, Registry),
    Response = case Result of
        {ok, Content} ->
            WireContent = [format_mcp_content(C) || C <- Content],
            copilot_protocol:encode_response(
                ReqId, #{<<"resultType">> => <<"success">>,
                         <<"content">> => WireContent});
        {error, ErrMsg} ->
            copilot_protocol:encode_response(
                ReqId, #{<<"resultType">> => <<"failure">>,
                         <<"error">> => ErrMsg})
    end,
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data;
handle_server_request(ReqId, <<"tool.call">>, _Params, Data) ->
    %% No MCP registry — tool not found
    Response = copilot_protocol:encode_response(
        ReqId, #{<<"resultType">> => <<"failure">>,
                 <<"error">> => <<"No MCP servers registered">>}),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data;

%% permission.request — ask for permission
handle_server_request(ReqId, <<"permission.request">>, Params, Data) ->
    Request = maps:get(<<"request">>, Params, Params),
    Invocation = maps:get(<<"invocation">>, Params, #{}),
    Data1 = call_permission_handler(ReqId, Request, Data),
    %% Also emit as an event for consumer visibility.
    %% Serialize Request map to binary for agent_wire:message() compliance.
    ContentBin = iolist_to_binary(json:encode(Request)),
    EventMsg = #{type => control_request, subtype => <<"permission_request">>,
                 content => ContentBin,
                 timestamp => erlang:system_time(millisecond),
                 permission_kind => maps:get(<<"kind">>, Request, <<"unknown">>),
                 raw => #{request => Request, invocation => Invocation}},
    deliver_or_enqueue(EventMsg, Data1);

%% hooks.invoke — invoke SDK hooks
handle_server_request(ReqId, <<"hooks.invoke">>, Params, Data) ->
    HookType = maps:get(<<"hookType">>, Params, <<>>),
    Input = maps:get(<<"input">>, Params, #{}),
    _Context = maps:get(<<"context">>, Params, #{}),
    call_hook_handler(ReqId, HookType, Input, Data);

%% user_input.request — ask user for input
handle_server_request(ReqId, <<"user_input.request">>, Params, Data) ->
    call_user_input_handler(ReqId, Params, Data);

%% Unknown server request — respond with method not found
handle_server_request(ReqId, Method, _Params, Data) ->
    logger:warning("Unknown server request: ~s", [Method]),
    Response = copilot_protocol:encode_error_response(
        ReqId, -32601, <<"Method not found: ", Method/binary>>),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.

%% @private Call the permission handler and respond.
-spec call_permission_handler(binary() | integer(), map(), #data{}) -> #data{}.
call_permission_handler(ReqId, Request, Data) ->
    Result = case Data#data.permission_handler of
        undefined ->
            %% No handler — deny (fail-closed)
            copilot_protocol:build_permission_result(undefined);
        Handler ->
            try
                Invocation = #{session_id => Data#data.copilot_session_id},
                case Handler(Request, Invocation) of
                    PermResult -> copilot_protocol:build_permission_result(PermResult)
                end
            catch
                _:_ ->
                    %% Handler crashed — deny (fail-closed)
                    copilot_protocol:build_permission_result(undefined)
            end
    end,
    Response = copilot_protocol:encode_response(ReqId, Result),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.

%% @private Call the hook handler and respond.
-spec call_hook_handler(binary() | integer(), binary(), map(), #data{}) -> #data{}.
call_hook_handler(ReqId, HookType, Input, Data) ->
    Result = case Data#data.sdk_hook_registry of
        undefined -> #{};
        _Registry ->
            %% Map Copilot hook types to agent_wire_hooks events
            Event = case HookType of
                <<"preToolUse">> -> pre_tool_use;
                <<"postToolUse">> -> post_tool_use;
                <<"userPromptSubmitted">> -> user_prompt_submit;
                <<"sessionStart">> -> session_start;
                <<"sessionEnd">> -> session_end;
                <<"errorOccurred">> -> error_occurred;
                _ -> unknown_hook
            end,
            case Event of
                unknown_hook -> #{};
                _ ->
                    case fire_hook(Event, Input, Data) of
                        ok -> #{};
                        {deny, Reason} ->
                            #{<<"permissionDecision">> => <<"deny">>,
                              <<"permissionDecisionReason">> => Reason};
                        HookResult when is_map(HookResult) -> HookResult;
                        _ -> #{}
                    end
            end
    end,
    WireResult = copilot_protocol:build_hook_result(Result),
    Response = copilot_protocol:encode_response(ReqId, WireResult),
    port_command(Data#data.port, copilot_frame:encode_message(Response)),
    Data.

%% @private Call the user input handler and respond.
-spec call_user_input_handler(binary() | integer(), map(), #data{}) -> #data{}.
call_user_input_handler(ReqId, Params, Data) ->
    case Data#data.user_input_handler of
        undefined ->
            Response = copilot_protocol:encode_error_response(
                ReqId, -32603, <<"No user input handler registered">>),
            port_command(Data#data.port, copilot_frame:encode_message(Response)),
            Data;
        Handler ->
            try
                Request = #{
                    question => maps:get(<<"question">>, Params, <<>>),
                    choices => maps:get(<<"choices">>, Params, []),
                    allow_freeform => maps:get(<<"allowFreeform">>, Params, true)
                },
                Ctx = #{session_id => Data#data.copilot_session_id},
                case Handler(Request, Ctx) of
                    InputResult when is_map(InputResult) ->
                        WireResult = copilot_protocol:build_user_input_result(InputResult),
                        Resp = copilot_protocol:encode_response(ReqId, WireResult),
                        port_command(Data#data.port,
                                    copilot_frame:encode_message(Resp)),
                        Data
                end
            catch
                Class:Reason:_Stack ->
                    ErrMsg = iolist_to_binary(
                        io_lib:format("User input handler error: ~p:~p",
                                      [Class, Reason])),
                    ErrResp = copilot_protocol:encode_error_response(
                        ReqId, -32603, ErrMsg),
                    port_command(Data#data.port,
                                copilot_frame:encode_message(ErrResp)),
                    Data
            end
    end.

%%====================================================================
%% Internal: Message Handling Per State
%%====================================================================

%% @private Handle messages during connecting state.
%%          The ping response is handled internally by dispatch_jsonrpc
%%          (removes from pending). We just check if pending is empty.
-spec handle_connecting_messages([map()], #data{}) ->
    {ping_ok, #data{}} | {wait, #data{}}.
handle_connecting_messages(_Events, Data) ->
    case maps:size(Data#data.pending) of
        0 -> {ping_ok, Data};
        _ -> {wait, Data}
    end.

%% @private Handle messages during initializing state.
%%          We're waiting for the session.create response.
-spec handle_init_messages([map()], #data{}) ->
    {session_created, binary(), #data{}} | {wait, #data{}}.
handle_init_messages([], Data) ->
    %% Check if session.create response was received (pending cleared by dispatch_jsonrpc)
    %% Actually, we need to capture the session ID from the response.
    %% The response is handled in dispatch_jsonrpc → handle_response,
    %% but for 'internal' requests we don't have it yet.
    %% Let's check if copilot_session_id was set.
    case Data#data.copilot_session_id of
        undefined -> {wait, Data};
        SessionId -> {session_created, SessionId, Data}
    end;
handle_init_messages([_Event | Rest], Data) ->
    handle_init_messages(Rest, Data).

%% @private Handle messages in ready state (background notifications).
-spec handle_ready_messages([map()], #data{}) -> #data{}.
handle_ready_messages([], Data) -> Data;
handle_ready_messages([Event | Rest], Data) ->
    %% Normalize and log/ignore — no consumer in ready state
    _Msg = copilot_protocol:normalize_event(Event),
    handle_ready_messages(Rest, Data).

%% @private Handle messages in active_query state.
%%          Normalize events and deliver to consumer.
%%
%%          For result events (session.idle): if a consumer is parked
%%          (waiting), deliver directly and signal transition to ready.
%%          If no consumer (all messages arrived before consumer pulled),
%%          enqueue the result and stay in active_query — the consumer
%%          will pull it via receive_message, which then triggers the
%%          transition. This prevents the race where fast mocks deliver
%%          all messages in a single port chunk before the consumer calls
%%          receive_message.
-spec handle_active_messages([map()], #data{}) -> #data{}.
handle_active_messages([], Data) -> Data;
handle_active_messages([Event | Rest], Data) ->
    Msg = copilot_protocol:normalize_event(Event),
    case maps:get(type, Msg) of
        result ->
            %% session.idle — query complete
            maybe_span_stop(Data),
            _ = fire_hook(stop, Msg, Data),
            ConsumerWaiting = Data#data.consumer =/= undefined,
            Data1 = deliver_or_enqueue(Msg, Data),
            case ConsumerWaiting of
                true ->
                    %% Result delivered directly to consumer — safe to clear
                    Data1#data{msg_queue = undefined, consumer = undefined,
                               query_ref = undefined,
                               query_start_time = undefined};
                false ->
                    %% Result enqueued — consumer will pull it later.
                    %% Stay in active_query (DON'T clear msg_queue).
                    Data1#data{query_start_time = undefined}
            end;
        tool_use ->
            _ = fire_hook(pre_tool_use, Msg, Data),
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1);
        tool_result ->
            _ = fire_hook(post_tool_use, Msg, Data),
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1);
        _ ->
            Data1 = deliver_or_enqueue(Msg, Data),
            handle_active_messages(Rest, Data1)
    end.

%%====================================================================
%% Internal: Consumer Demand
%%====================================================================

%% @private Check if a message is terminal (signals query completion).
-spec is_terminal_message(agent_wire:message()) -> boolean().
is_terminal_message(#{type := result}) -> true;
is_terminal_message(#{type := error, is_error := true}) -> true;
is_terminal_message(_) -> false.

%% @private Deliver a message to the waiting consumer, or enqueue it.
-spec deliver_or_enqueue(agent_wire:message(), #data{}) -> #data{}.
deliver_or_enqueue(Msg, #data{consumer = undefined, msg_queue = Queue} = Data)
  when Queue =/= undefined ->
    Data#data{msg_queue = queue:in(Msg, Queue)};
deliver_or_enqueue(Msg, #data{consumer = Consumer} = Data)
  when Consumer =/= undefined ->
    gen_statem:reply(Consumer, {ok, Msg}),
    Data#data{consumer = undefined};
deliver_or_enqueue(_Msg, Data) ->
    %% No queue and no consumer — drop (shouldn't happen in normal flow)
    Data.

%%====================================================================
%% Internal: Hook Firing
%%====================================================================

%% @private Fire an SDK hook. Returns ok, {deny, Reason}, or hook result.
-spec fire_hook(atom(), map(), #data{}) -> ok | {deny, binary()} | term().
fire_hook(Event, Context, #data{sdk_hook_registry = undefined}) ->
    _ = Event,
    _ = Context,
    ok;
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    agent_wire_hooks:fire(Event, Context, Registry).

%%====================================================================
%% Internal: Utilities
%%====================================================================

%% @private Generate the next request ID (binary UUID-style).
-spec make_request_id(#data{}) -> binary().
make_request_id(#data{next_id = N}) ->
    integer_to_binary(N).

%% @private Ensure ID is binary for map key consistency.
-spec ensure_binary_id(binary() | integer()) -> binary().
ensure_binary_id(Id) when is_binary(Id) -> Id;
ensure_binary_id(Id) when is_integer(Id) -> integer_to_binary(Id).

%% @private Safely close a port.
-spec close_port(port() | undefined) -> ok.
close_port(undefined) -> ok;
close_port(Port) ->
    try port_close(Port) catch error:_ -> ok end,
    ok.

%% @private Cancel a timer reference.
-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) -> ok;
cancel_timer(TRef) -> _ = erlang:cancel_timer(TRef), ok.

%% @private Build session info map.
-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    Base = #{
        adapter => copilot,
        session_id => Data#data.copilot_session_id,
        model => Data#data.model,
        cli_path => list_to_binary(Data#data.cli_path)
    },
    case Data#data.copilot_session_id of
        undefined -> Base;
        SId -> Base#{copilot_session_id => SId}
    end.

%% @private Build MCP registry from sdk_mcp_servers option.
-spec build_mcp_registry(map()) -> agent_wire_mcp:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    agent_wire_mcp:build_registry(maps:get(sdk_mcp_servers, Opts, undefined)).

%% @private Format an MCP content result for Copilot wire protocol.
-spec format_mcp_content(agent_wire_mcp:content_result()) -> map().
format_mcp_content(#{type := text, text := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_mcp_content(#{type := image, data := ImgData, mime_type := Mime}) ->
    #{<<"type">> => <<"image">>, <<"data">> => ImgData,
      <<"mimeType">> => Mime}.

%%====================================================================
%% Internal: Telemetry Span Helpers
%%====================================================================

-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) -> ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    agent_wire_telemetry:span_stop(copilot, query, StartTime).

-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) -> ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    agent_wire_telemetry:span_exception(copilot, query, Reason).
