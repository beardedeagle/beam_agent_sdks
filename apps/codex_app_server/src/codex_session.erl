%%%-------------------------------------------------------------------
%%% @doc Codex CLI app-server wire protocol adapter — gen_statem.
%%%
%%% Primary adapter for `codex --app-server` mode. Implements full
%%% bidirectional JSON-RPC over stdio with the Codex CLI.
%%%
%%% State machine:
%%%   initializing -> ready -> active_turn -> ready -> ...
%%%                             |
%%%                             +-> error -> (terminate)
%%%
%%% Key differences from claude_agent_session:
%%%   - JSON-RPC envelope (no "jsonrpc" field on wire — Codex omits it)
%%%   - 3-step initialize handshake (request → response → notification)
%%%   - Thread/turn model (persistent threads, discrete turns)
%%%   - Server-initiated requests (approval callbacks)
%%%   - Integer request IDs (auto-incrementing per session)
%%%
%%% Implements agent_wire_behaviour for unified consumer API.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_session).

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

%% gen_statem callbacks
-export([
    callback_mode/0,
    init/1,
    terminate/3
]).

%% State functions
-export([
    initializing/3,
    ready/3,
    active_turn/3,
    error/3
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type state_name() :: initializing | ready | active_turn | error.

-type state_callback_result() ::
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).

-export_type([state_name/0]).

%% Internal helpers with intentionally broad specs.
-dialyzer({no_underspecs, [
    build_session_info/1,
    build_port_opts/1,
    build_cli_args/1,
    build_approval_response/2,
    put_new/3
]}).
-dialyzer({nowarn_function, [call_approval_handler/3]}).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(data, {
    %% Port & buffer (same pattern as claude_agent_session)
    port               :: port() | undefined,
    buffer = <<>>      :: binary(),
    buffer_max         :: pos_integer(),

    %% JSON-RPC correlation
    pending = #{}      :: #{integer() => {gen_statem:from(), reference()}},

    %% Consumer demand (same as claude_agent_session)
    consumer           :: gen_statem:from() | undefined,
    query_ref          :: reference() | undefined,
    msg_queue          :: queue:queue() | undefined,

    %% Codex session state
    thread_id          :: binary() | undefined,
    turn_id            :: binary() | undefined,
    server_info = #{}  :: map(),

    %% Configuration
    opts               :: map(),
    cli_path           :: string(),
    model              :: binary() | undefined,
    approval_policy    :: binary() | undefined,
    sandbox_mode       :: binary() | undefined,

    %% Callbacks
    approval_handler   :: fun((binary(), map(), map()) ->
                               codex_protocol:approval_decision()) | undefined,

    %% Shared infrastructure (from agent_wire)
    sdk_hook_registry  :: agent_wire_hooks:hook_registry() | undefined,
    sdk_mcp_registry   :: agent_wire_mcp:mcp_registry() | undefined,
    %% Query span telemetry (monotonic start time)
    query_start_time   :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% Defaults
%%--------------------------------------------------------------------

-define(DEFAULT_BUFFER_MAX, 2 * 1024 * 1024).  %% 2MB
-define(INIT_TIMEOUT, 15000).
-define(DEFAULT_CLI, "codex").
-define(SDK_VERSION, "0.1.0").
-define(ERROR_STATE_TIMEOUT, 60000).

%%====================================================================
%% agent_wire_behaviour API
%%====================================================================

-spec start_link(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-spec send_query(pid(), binary(), agent_wire:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

-spec receive_message(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).

-spec send_control(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_control(Pid, Method, Params) ->
    gen_statem:call(Pid, {send_control, Method, Params}, 30000).

-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).

-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).

-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(Pid, Mode) ->
    gen_statem:call(Pid, {set_permission_mode, Mode}, 5000).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(initializing) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = maps:get(cli_path, Opts, os:getenv("CODEX_CLI_PATH", ?DEFAULT_CLI)),
    BufferMax = maps:get(buffer_max, Opts, ?DEFAULT_BUFFER_MAX),
    Model = maps:get(model, Opts, undefined),
    ApprovalPolicy = case maps:get(approval_policy, Opts, undefined) of
        undefined -> undefined;
        AP when is_atom(AP) -> codex_protocol:encode_ask_for_approval(AP);
        AP when is_binary(AP) -> AP
    end,
    SandboxMode = case maps:get(sandbox_mode, Opts, undefined) of
        undefined -> undefined;
        SM when is_atom(SM) -> codex_protocol:encode_sandbox_mode(SM);
        SM when is_binary(SM) -> SM
    end,
    ApprovalHandler = maps:get(approval_handler, Opts, undefined),
    HookRegistry = build_hook_registry(Opts),
    McpRegistry = build_mcp_registry(Opts),

    Data = #data{
        opts = Opts,
        cli_path = CliPath,
        buffer_max = BufferMax,
        model = Model,
        approval_policy = ApprovalPolicy,
        sandbox_mode = SandboxMode,
        approval_handler = ApprovalHandler,
        sdk_hook_registry = HookRegistry,
        sdk_mcp_registry = McpRegistry,
        msg_queue = queue:new()
    },

    case open_port_safe(Data) of
        {ok, Port} ->
            %% Codex is client-initiated: we send initialize first.
            %% Go directly to initializing (no waiting for server data).
            {ok, initializing, Data#data{port = Port},
             [{state_timeout, ?INIT_TIMEOUT, init_timeout}]};
        {error, Reason} ->
            logger:warning("Codex session failed to open port: ~p", [Reason]),
            {stop, {shutdown, {open_port_failed, Reason}}}
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = Port} = Data) ->
    %% Fire session_end hook
    _ = fire_hook(session_end, #{event => session_end, reason => Reason}, Data),
    close_port(Port),
    ok.

%%====================================================================
%% State: initializing
%%====================================================================

-spec initializing(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
initializing(enter, initializing, Data) ->
    %% Send the initialize request (first step of 3-step handshake).
    %% OldState is `initializing` when entering from init/1 (initial state).
    agent_wire_telemetry:state_change(codex, undefined, initializing),
    Id = agent_wire_jsonrpc:next_id(),
    InitParams = codex_protocol:initialize_params(Data#data.opts),
    send_json(agent_wire_jsonrpc:encode_request(Id, <<"initialize">>, InitParams), Data),
    %% Store pending correlation with special 'init' marker
    Pending = (Data#data.pending)#{Id => init},
    {keep_state, Data#data{pending = Pending}};

initializing(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(codex, OldState, initializing),
    keep_state_and_data;

initializing(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_initializing_buffer(Data1);

initializing(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};

initializing(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop},
      {next_event, internal, {port_exit, Status}}]};

initializing(state_timeout, init_timeout, Data) ->
    {next_state, error, Data,
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

initializing({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, initializing}]};

initializing({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

initializing({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%%====================================================================
%% State: ready
%%====================================================================

-spec ready(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
ready(enter, initializing, Data) ->
    agent_wire_telemetry:state_change(codex, initializing, ready),
    %% Fire session_start hook
    _ = fire_hook(session_start, #{event => session_start,
                                    system_info => Data#data.server_info}, Data),
    keep_state_and_data;

ready(enter, active_turn, _Data) ->
    agent_wire_telemetry:state_change(codex, active_turn, ready),
    keep_state_and_data;

ready(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(codex, OldState, ready),
    keep_state_and_data;

ready(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    %% Buffer data even in ready state (server can send notifications)
    Data1 = buffer_line(Line, Data),
    process_ready_buffer(Data1);

ready(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};

ready(info, {Port, {exit_status, _Status}}, #data{port = Port} = Data) ->
    {next_state, error, Data#data{port = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

ready({call, From}, {send_query, Prompt, Params}, Data) ->
    %% Fire user_prompt_submit hook (blocking — can deny)
    HookCtx = #{event => user_prompt_submit,
                 prompt => Prompt, params => Params},
    case fire_hook(user_prompt_submit, HookCtx, Data) of
        {deny, Reason} ->
            {keep_state_and_data, [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_send_query(From, Prompt, Params, Data)
    end;

ready({call, From}, {send_control, Method, Params}, Data) ->
    do_send_control(From, Method, Params, Data);

ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

ready({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};

ready({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state, Data#data{approval_policy = Mode}, [{reply, From, {ok, Mode}}]};

ready({call, From}, {receive_message, Ref}, #data{query_ref = Ref, msg_queue = Q} = Data) ->
    %% Drain remaining messages from a completed turn
    case Q of
        undefined ->
            {keep_state, Data#data{query_ref = undefined},
             [{reply, From, {error, complete}}]};
        _ ->
            case queue:out(Q) of
                {{value, Msg}, Q1} ->
                    {keep_state, Data#data{msg_queue = Q1},
                     [{reply, From, {ok, Msg}}]};
                {empty, _} ->
                    {keep_state, Data#data{query_ref = undefined, msg_queue = undefined},
                     [{reply, From, {error, complete}}]}
            end
    end;

ready({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

ready(info, {pending_timeout, Id}, #data{pending = Pending} = Data) ->
    %% Stale pending entry — caller already timed out on gen_statem:call.
    %% Just clean up the map.
    {keep_state, Data#data{pending = maps:remove(Id, Pending)}};

ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.

%%====================================================================
%% State: active_turn
%%====================================================================

-spec active_turn(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
active_turn(enter, ready, _Data) ->
    agent_wire_telemetry:state_change(codex, ready, active_turn),
    keep_state_and_data;

active_turn(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(codex, OldState, active_turn),
    keep_state_and_data;

active_turn(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_active_buffer(Data1);

active_turn(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};

active_turn(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    %% Port died during active turn — notify consumer
    maybe_span_exception(Data, {port_exit, Status}),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    case Data1#data.consumer of
        undefined ->
            {next_state, error, Data1,
             [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};
        From ->
            Data2 = Data1#data{consumer = undefined, query_ref = undefined},
            {next_state, error, Data2,
             [{reply, From, {error, port_closed}},
              {state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end;

active_turn({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);

active_turn({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_turn({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

active_turn({call, From}, interrupt, Data) ->
    case Data#data.turn_id of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, no_active_turn}}]};
        TurnId ->
            Id = agent_wire_jsonrpc:next_id(),
            Params = #{<<"turnId">> => TurnId},
            send_json(agent_wire_jsonrpc:encode_request(
                Id, <<"turn/interrupt">>, Params), Data),
            {keep_state_and_data, [{reply, From, ok}]}
    end;

active_turn({call, From}, {send_control, Method, Params}, Data) ->
    do_send_control(From, Method, Params, Data);

active_turn({call, From}, health, _Data) ->
    %% Maps to `active_query` for agent_wire_behaviour API consistency
    %% (consumers see a unified health vocabulary across all adapters).
    {keep_state_and_data, [{reply, From, active_query}]};

active_turn({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

active_turn({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};

active_turn({call, From}, {set_permission_mode, Mode}, Data) ->
    {keep_state, Data#data{approval_policy = Mode}, [{reply, From, {ok, Mode}}]};

active_turn(info, {pending_timeout, Id}, #data{pending = Pending} = Data) ->
    %% Stale pending entry — caller already timed out.
    {keep_state, Data#data{pending = maps:remove(Id, Pending)}};

active_turn({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
error(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(codex, OldState, error),
    keep_state_and_data;

error(internal, {port_exit, _Status}, _Data) ->
    keep_state_and_data;

error(state_timeout, auto_stop, _Data) ->
    {stop, normal};

error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};

error({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

%%====================================================================
%% Internal: Port Management
%%====================================================================

-spec open_port_safe(#data{}) -> {ok, port()} | {error, term()}.
open_port_safe(Data) ->
    try
        {CliPath, PortOpts} = build_port_opts(Data),
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        {ok, Port}
    catch
        error:Reason -> {error, Reason}
    end.

-spec build_port_opts(#data{}) -> {string(), list()}.
build_port_opts(#data{cli_path = CliPath, opts = Opts}) ->
    WorkDir = maps:get(work_dir, Opts, undefined),
    Env = maps:get(env, Opts, []),
    BaseEnv = [{"CODEX_SDK_VERSION", ?SDK_VERSION} | Env],
    Args = build_cli_args(Opts),
    PortOpts = [{args, Args}, {line, 65536}, binary, exit_status, use_stdio,
                {env, BaseEnv}],
    case WorkDir of
        undefined -> {CliPath, PortOpts};
        Dir -> {CliPath, [{cd, Dir} | PortOpts]}
    end.

-spec build_cli_args(map()) -> [string()].
build_cli_args(_Opts) ->
    ["--app-server"].

-spec close_port(port() | undefined) -> ok.
close_port(Port) ->
    codex_port_utils:close_port(Port).

-spec send_json(iodata(), #data{}) -> ok.
send_json(Iodata, #data{port = Port}) when Port =/= undefined ->
    port_command(Port, Iodata),
    ok;
send_json(_Iodata, _Data) ->
    ok.

%%====================================================================
%% Internal: Buffer Management
%%====================================================================

-spec buffer_line(binary(), #data{}) -> #data{}.
buffer_line(Line, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = codex_port_utils:buffer_line(Line, Buffer, Max)}.

-spec append_buffer(binary(), #data{}) -> #data{}.
append_buffer(Partial, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = codex_port_utils:append_buffer(Partial, Buffer, Max)}.

%%====================================================================
%% Internal: Initialize Handshake
%%====================================================================

-spec process_initializing_buffer(#data{}) -> state_callback_result().
process_initializing_buffer(Data) ->
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case agent_wire_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_init_message(agent_wire_jsonrpc:decode(Map), Map, Data1);
                {error, _} ->
                    %% Skip bad JSON during init
                    process_initializing_buffer(Data1)
            end
    end.

-spec handle_init_message(agent_wire_jsonrpc:jsonrpc_msg(), map(), #data{}) ->
    state_callback_result().
handle_init_message({response, Id, Result}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, init} ->
            %% Initialize response received — store server info and send `initialized`
            Pending1 = maps:remove(Id, Data#data.pending),
            Data1 = Data#data{pending = Pending1, server_info = Result},
            %% Send the `initialized` notification (step 3 of handshake)
            send_json(agent_wire_jsonrpc:encode_notification(
                <<"initialized">>, undefined), Data1),
            %% Transition to ready
            {next_state, ready, Data1};
        _ ->
            %% Unknown response during init — keep waiting
            process_initializing_buffer(Data)
    end;
handle_init_message({error_response, Id, _Code, Msg, _ErrData}, _Raw, Data) ->
    Pending1 = maps:remove(Id, Data#data.pending),
    logger:error("Codex initialize failed: ~s", [Msg]),
    {next_state, error, Data#data{pending = Pending1},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};
handle_init_message(_Other, _Raw, Data) ->
    %% Skip notifications during init (e.g., status updates)
    process_initializing_buffer(Data).

%%====================================================================
%% Internal: Ready State Buffer Processing
%%====================================================================

-spec process_ready_buffer(#data{}) -> state_callback_result().
process_ready_buffer(Data) ->
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case agent_wire_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_ready_message(agent_wire_jsonrpc:decode(Map), Map, Data1);
                {error, _} ->
                    process_ready_buffer(Data1)
            end
    end.

-spec handle_ready_message(agent_wire_jsonrpc:jsonrpc_msg(), map(), #data{}) ->
    state_callback_result().
handle_ready_message({response, Id, Result}, _Raw, Data) ->
    %% Response to a send_control call
    case maps:find(Id, Data#data.pending) of
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state, Data#data{pending = Pending1},
             [{reply, From, {ok, Result}}]};
        _ ->
            {keep_state, Data}
    end;
handle_ready_message({error_response, Id, _Code, Msg, _ErrData}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state, Data#data{pending = Pending1},
             [{reply, From, {error, Msg}}]};
        _ ->
            {keep_state, Data}
    end;
handle_ready_message({request, Id, Method, Params}, _Raw, Data) ->
    %% Server-initiated request (approval callback)
    Data1 = handle_server_request(Id, Method, Params, Data),
    process_ready_buffer(Data1);
handle_ready_message({notification, _Method, _Params}, _Raw, Data) ->
    %% Notifications in ready state — ignore (no active consumer)
    process_ready_buffer(Data);
handle_ready_message(_Other, _Raw, Data) ->
    process_ready_buffer(Data).

%%====================================================================
%% Internal: Active Turn Buffer Processing
%%====================================================================

-spec process_active_buffer(#data{}) -> state_callback_result().
process_active_buffer(Data) ->
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            %% No complete line — if consumer is waiting, stay waiting
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case agent_wire_jsonl:decode_line(Line) of
                {ok, Map} ->
                    handle_active_message(agent_wire_jsonrpc:decode(Map), Map, Data1);
                {error, _} ->
                    process_active_buffer(Data1)
            end
    end.

-spec handle_active_message(agent_wire_jsonrpc:jsonrpc_msg(), map(), #data{}) ->
    state_callback_result().
handle_active_message({notification, Method, Params}, _Raw, Data) ->
    SafeParams = case Params of undefined -> #{}; P -> P end,
    Msg = codex_protocol:normalize_notification(Method, SafeParams),
    %% Fire hooks for relevant notifications
    Data1 = fire_notification_hooks(Method, SafeParams, Msg, Data),
    %% Check for turn completion
    case Method of
        <<"turn/completed">> ->
            %% Fire stop hook
            maybe_span_stop(Data1),
            _ = fire_hook(stop, #{event => stop,
                                  stop_reason => maps:get(<<"status">>, SafeParams, <<>>)}, Data1),
            %% Keep query_ref so consumer can drain remaining queued messages
            deliver_or_enqueue(Msg, Data1, fun(D) ->
                {next_state, ready, D#data{turn_id = undefined,
                                            consumer = undefined,
                                            query_start_time = undefined}}
            end);
        _ ->
            deliver_or_enqueue(Msg, Data1, fun(D) ->
                process_active_buffer(D)
            end)
    end;

handle_active_message({request, Id, Method, Params}, _Raw, Data) ->
    %% Server-initiated request during turn (approval callbacks)
    Data1 = handle_server_request(Id, Method, Params, Data),
    process_active_buffer(Data1);

handle_active_message({response, Id, Result}, _Raw, Data) ->
    %% Response to a pending control request during active turn
    case maps:find(Id, Data#data.pending) of
        {ok, {thread_then_turn, Prompt, Opts}} ->
            %% thread/start response — extract threadId, send turn/start
            Pending1 = maps:remove(Id, Data#data.pending),
            ThreadId = maps:get(<<"threadId">>, Result, undefined),
            Data1 = Data#data{pending = Pending1, thread_id = ThreadId},
            %% Now send the turn/start request
            TurnId = agent_wire_jsonrpc:next_id(),
            TurnParams = codex_protocol:turn_start_params(ThreadId, Prompt, Opts),
            send_json(agent_wire_jsonrpc:encode_request(
                TurnId, <<"turn/start">>, TurnParams), Data1),
            Data2 = Data1#data{pending = (Data1#data.pending)#{TurnId => turn_start}},
            process_active_buffer(Data2);
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            Data1 = Data#data{pending = Pending1},
            %% Check if this is a turn/start or thread/start response
            ThreadId = maps:get(<<"threadId">>, Result, Data1#data.thread_id),
            TurnId = maps:get(<<"turnId">>, Result, Data1#data.turn_id),
            Data2 = Data1#data{thread_id = ThreadId, turn_id = TurnId},
            {keep_state, Data2, [{reply, From, {ok, Result}}]};
        {ok, turn_start} ->
            %% Internal turn/start response (no external From)
            Pending1 = maps:remove(Id, Data#data.pending),
            ThreadId = maps:get(<<"threadId">>, Result, Data#data.thread_id),
            TurnId = maps:get(<<"turnId">>, Result, Data#data.turn_id),
            Data1 = Data#data{pending = Pending1,
                              thread_id = ThreadId,
                              turn_id = TurnId},
            process_active_buffer(Data1);
        _ ->
            process_active_buffer(Data)
    end;

handle_active_message({error_response, Id, _Code, Msg, _ErrData}, _Raw, Data) ->
    case maps:find(Id, Data#data.pending) of
        {ok, {thread_then_turn, _Prompt, _Opts}} ->
            %% thread/start failed — notify consumer via error message
            maybe_span_exception(Data, {thread_start_failed, Msg}),
            Pending1 = maps:remove(Id, Data#data.pending),
            ErrorMsg = #{type => error, content => Msg,
                         timestamp => erlang:system_time(millisecond)},
            Data1 = Data#data{pending = Pending1, query_start_time = undefined},
            deliver_or_enqueue(ErrorMsg, Data1, fun(D) ->
                {next_state, ready, D#data{consumer = undefined,
                                            query_ref = undefined}}
            end);
        {ok, {From, TimerRef}} ->
            _ = erlang:cancel_timer(TimerRef),
            Pending1 = maps:remove(Id, Data#data.pending),
            {keep_state, Data#data{pending = Pending1},
             [{reply, From, {error, Msg}}]};
        {ok, turn_start} ->
            %% turn/start failed — notify consumer via error message
            maybe_span_exception(Data, {turn_start_failed, Msg}),
            Pending1 = maps:remove(Id, Data#data.pending),
            ErrorMsg = #{type => error, content => Msg,
                         timestamp => erlang:system_time(millisecond)},
            Data1 = Data#data{pending = Pending1, query_start_time = undefined},
            deliver_or_enqueue(ErrorMsg, Data1, fun(D) ->
                {next_state, ready, D#data{consumer = undefined,
                                            query_ref = undefined}}
            end);
        _ ->
            process_active_buffer(Data)
    end;

handle_active_message(_Other, _Raw, Data) ->
    process_active_buffer(Data).

%%====================================================================
%% Internal: Query Dispatch
%%====================================================================

-spec do_send_query(gen_statem:from(), binary(), map(), #data{}) ->
    state_callback_result().
do_send_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime = agent_wire_telemetry:span_start(codex, query, #{prompt => Prompt}),
    MergedOpts = merge_turn_opts(Params, Data),
    Data1 = Data#data{query_start_time = StartTime},
    case Data1#data.thread_id of
        undefined ->
            %% Auto-create thread, then start turn
            do_create_thread_and_turn(From, Ref, Prompt, MergedOpts, Data1);
        ThreadId ->
            %% Thread exists — start turn directly
            do_start_turn(From, Ref, ThreadId, Prompt, MergedOpts, Data1)
    end.

-spec do_create_thread_and_turn(gen_statem:from(), reference(), binary(),
                                 map(), #data{}) ->
    state_callback_result().
do_create_thread_and_turn(From, Ref, Prompt, Opts, Data) ->
    %% Send thread/start
    ThreadId1 = agent_wire_jsonrpc:next_id(),
    ThreadParams = codex_protocol:thread_start_params(Opts),
    send_json(agent_wire_jsonrpc:encode_request(
        ThreadId1, <<"thread/start">>, ThreadParams), Data),
    %% We need the thread/start response before sending turn/start
    %% Store the prompt info for use when thread response arrives
    Data1 = Data#data{
        consumer = From,
        query_ref = Ref,
        msg_queue = queue:new(),
        pending = (Data#data.pending)#{ThreadId1 => {thread_then_turn, Prompt, Opts}}
    },
    {next_state, active_turn, Data1, [{reply, From, {ok, Ref}}]}.

-spec do_start_turn(gen_statem:from(), reference(), binary(), binary(),
                     map(), #data{}) ->
    state_callback_result().
do_start_turn(From, Ref, ThreadId, Prompt, Opts, Data) ->
    Id = agent_wire_jsonrpc:next_id(),
    TurnParams = codex_protocol:turn_start_params(ThreadId, Prompt, Opts),
    send_json(agent_wire_jsonrpc:encode_request(Id, <<"turn/start">>, TurnParams), Data),
    Data1 = Data#data{
        consumer = From,
        query_ref = Ref,
        msg_queue = queue:new(),
        pending = (Data#data.pending)#{Id => turn_start}
    },
    {next_state, active_turn, Data1, [{reply, From, {ok, Ref}}]}.

-spec merge_turn_opts(map(), #data{}) -> map().
merge_turn_opts(Params, Data) ->
    M0 = Params,
    M1 = case Data#data.model of
        undefined -> M0;
        Model -> put_new(model, Model, M0)
    end,
    M2 = case Data#data.approval_policy of
        undefined -> M1;
        AP -> put_new(approval_policy, AP, M1)
    end,
    case Data#data.sandbox_mode of
        undefined -> M2;
        SM -> put_new(sandbox_mode, SM, M2)
    end.

-spec put_new(term(), term(), map()) -> map().
put_new(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> Map#{Key => Value}
    end.

%%====================================================================
%% Internal: Control Message Dispatch
%%====================================================================

-spec do_send_control(gen_statem:from(), binary(), map(), #data{}) ->
    state_callback_result().
do_send_control(From, Method, Params, Data) ->
    Id = agent_wire_jsonrpc:next_id(),
    send_json(agent_wire_jsonrpc:encode_request(Id, Method, Params), Data),
    %% Timer fires after the caller's gen_statem:call timeout (30s) to clean
    %% up stale pending entries.  If the response arrives first, the timer is
    %% cancelled in the response/error handler.
    TimerRef = erlang:send_after(35000, self(), {pending_timeout, Id}),
    Pending = (Data#data.pending)#{Id => {From, TimerRef}},
    {keep_state, Data#data{pending = Pending}}.

%%====================================================================
%% Internal: Server-Initiated Request Handling
%%====================================================================

-spec handle_server_request(integer(), binary(), map() | undefined, #data{}) -> #data{}.
handle_server_request(Id, <<"mcp/message">>, Params, #data{sdk_mcp_registry = Registry} = Data)
  when is_map(Registry) ->
    SafeParams = case Params of undefined -> #{}; P -> P end,
    ServerName = maps:get(<<"server_name">>, SafeParams, <<>>),
    Message = maps:get(<<"message">>, SafeParams, #{}),
    case agent_wire_mcp:handle_mcp_message(ServerName, Message, Registry) of
        {ok, McpResponse} ->
            send_json(agent_wire_jsonrpc:encode_response(Id, McpResponse), Data),
            Data;
        {error, ErrMsg} ->
            ErrResponse = #{<<"error">> => ErrMsg},
            send_json(agent_wire_jsonrpc:encode_response(Id, ErrResponse), Data),
            Data
    end;
handle_server_request(Id, Method, Params, Data) ->
    SafeParams = case Params of undefined -> #{}; P -> P end,
    %% Fire pre_tool_use hook
    HookCtx = #{event => pre_tool_use,
                 tool_name => Method,
                 tool_input => SafeParams},
    case fire_hook(pre_tool_use, HookCtx, Data) of
        {deny, _Reason} ->
            %% Hook denied — send decline response
            ResponseMap = #{<<"decision">> => <<"decline">>},
            send_json(agent_wire_jsonrpc:encode_response(Id, ResponseMap), Data),
            Data;
        ok ->
            Decision = call_approval_handler(Method, SafeParams, Data),
            ResponseMap = build_approval_response(Method, Decision),
            send_json(agent_wire_jsonrpc:encode_response(Id, ResponseMap), Data),
            Data
    end.

-spec call_approval_handler(binary(), map(), #data{}) ->
    codex_protocol:approval_decision().
call_approval_handler(_Method, _Params, #data{approval_handler = undefined, opts = Opts}) ->
    %% Fail-closed by default; use permission_default => allow to auto-approve
    case maps:get(permission_default, Opts, deny) of
        allow -> accept;
        _     -> decline
    end;
call_approval_handler(Method, Params, #data{approval_handler = Handler}) ->
    try Handler(Method, Params, #{}) of
        Decision when is_atom(Decision) -> Decision;
        _ -> accept
    catch _:_ ->
        decline  %% Fail-closed on handler crash
    end.

-spec build_approval_response(binary(), codex_protocol:approval_decision()) -> map().
build_approval_response(<<"item/commandExecution/requestApproval">>, Decision) ->
    codex_protocol:command_approval_response(Decision);
build_approval_response(<<"item/fileChange/requestApproval">>, Decision) ->
    codex_protocol:file_approval_response(Decision);
build_approval_response(_, Decision) ->
    codex_protocol:command_approval_response(Decision).

%%====================================================================
%% Internal: Message Delivery
%%====================================================================

-spec try_deliver_message(gen_statem:from(), #data{}) -> state_callback_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            %% No message available — store consumer, wait for data
            Data1 = Data#data{consumer = From},
            %% Try to extract from buffer
            case agent_wire_jsonl:extract_line(Data1#data.buffer) of
                none ->
                    {keep_state, Data1};
                {ok, Line, Rest} ->
                    Data2 = Data1#data{buffer = Rest},
                    case agent_wire_jsonl:decode_line(Line) of
                        {ok, Map} ->
                            handle_active_message(
                                agent_wire_jsonrpc:decode(Map), Map, Data2);
                        {error, _} ->
                            {keep_state, Data2}
                    end
            end
    end.

-spec deliver_or_enqueue(agent_wire:message(), #data{},
                          fun((#data{}) -> state_callback_result())) ->
    state_callback_result().
deliver_or_enqueue(Msg, #data{consumer = undefined, msg_queue = Q} = Data, Continue) ->
    %% No consumer waiting — enqueue
    Q1 = queue:in(Msg, Q),
    Continue(Data#data{msg_queue = Q1});
deliver_or_enqueue(Msg, #data{consumer = From} = Data, Continue) ->
    %% Consumer waiting — deliver directly
    Data1 = Data#data{consumer = undefined},
    case Continue(Data1) of
        {next_state, NewState, NewData} ->
            {next_state, NewState, NewData, [{reply, From, {ok, Msg}}]};
        {next_state, NewState, NewData, Actions} ->
            {next_state, NewState, NewData, [{reply, From, {ok, Msg}} | Actions]};
        {keep_state, NewData} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}}]};
        {keep_state, NewData, Actions} ->
            {keep_state, NewData, [{reply, From, {ok, Msg}} | Actions]}
    end.

%%====================================================================
%% Internal: Hook Firing
%%====================================================================

-spec fire_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_context(),
                #data{}) -> ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    agent_wire_hooks:fire(Event, Context, Registry).

-spec fire_notification_hooks(binary(), map(), agent_wire:message(), #data{}) -> #data{}.
fire_notification_hooks(<<"item/completed">>, Params, _Msg, Data) ->
    %% Fire post_tool_use hook
    Item = maps:get(<<"item">>, Params, #{}),
    ToolName = maps:get(<<"command">>, Item,
                   maps:get(<<"filePath">>, Item, <<>>)),
    _ = fire_hook(post_tool_use, #{event => post_tool_use,
                                    tool_name => ToolName,
                                    content => maps:get(<<"output">>, Item, <<>>)}, Data),
    Data;
fire_notification_hooks(_, _, _, Data) ->
    Data.

%%====================================================================
%% Internal: Registry Building
%%====================================================================

-spec build_hook_registry(map()) -> agent_wire_hooks:hook_registry() | undefined.
build_hook_registry(Opts) ->
    agent_wire_hooks:build_registry(maps:get(sdk_hooks, Opts, undefined)).

-spec build_mcp_registry(map()) -> agent_wire_mcp:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    agent_wire_mcp:build_registry(maps:get(sdk_mcp_servers, Opts, undefined)).

%%====================================================================
%% Internal: Session Info
%%====================================================================

-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{thread_id => Data#data.thread_id,
      turn_id => Data#data.turn_id,
      server_info => Data#data.server_info,
      model => Data#data.model,
      approval_policy => Data#data.approval_policy,
      sandbox_mode => Data#data.sandbox_mode}.

%%====================================================================
%% Internal: Telemetry Span Helpers
%%====================================================================

-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) -> ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    agent_wire_telemetry:span_stop(codex, query, StartTime).

-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) -> ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    agent_wire_telemetry:span_exception(codex, query, Reason).
