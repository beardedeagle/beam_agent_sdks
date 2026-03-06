-module(opencode_session).

-moduledoc """
OpenCode HTTP+SSE adapter -- gen_statem.

Primary adapter for the OpenCode HTTP REST + SSE API. Uses `gun`
for persistent HTTP/1.1 connections. Maintains one long-lived SSE
stream for server-push events alongside discrete REST calls for
queries, session management, and permission replies.

State machine:

```
connecting -> initializing -> ready -> active_query -> ready -> ...
                                        |
                                        +-> error -> (terminate)
```

Key design decisions:
- SSE stream is opened immediately on connect (`gun_up`) and kept
  alive for the full session lifetime.
- REST requests are tracked in `rest_pending` map keyed by gun
  StreamRef, so multiple concurrent REST calls are possible.
- Permission handling is FAIL-CLOSED: deny by default, deny on
  handler crash.
- `session.idle` SSE event signals query completion (no drain
  phase needed, unlike port-based adapters).

Implements `agent_wire_behaviour` for unified consumer API.
""".

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

-type rest_purpose() :: create_session
                      | send_message
                      | abort_query
                      | permission_reply
                      | list_sessions
                      | get_session
                      | delete_session
                      | send_command
                      | server_health.

-export_type([state_name/0]).

-dialyzer({no_underspecs, [
    post_json/5,
    get_request/3,
    delete_request/3,
    build_sse_path/1,
    build_sse_headers/1,
    dispatch_sse_events/2,
    fire_hook/3,
    maybe_reply/2
]}).
-dialyzer({no_extra_return, [set_permission_mode/2]}).
-dialyzer({nowarn_function, [handle_permission/3]}).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(data, {
    %% Gun connection
    conn_pid           :: pid() | undefined,
    conn_monitor       :: reference() | undefined,
    sse_ref            :: reference() | undefined,
    sse_state          :: opencode_sse:parse_state(),

    %% REST request tracking: StreamRef -> {Purpose, From | undefined, BodyAcc}
    rest_pending = #{} :: #{reference() =>
                             {rest_purpose(), gen_statem:from() | undefined, binary()}},

    %% Consumer demand
    consumer           :: gen_statem:from() | undefined,
    query_ref          :: reference() | undefined,
    msg_queue          :: queue:queue() | undefined,

    %% Session state
    session_id         :: binary() | undefined,
    directory          :: binary(),

    %% Configuration
    opts               :: map(),
    host               :: binary(),
    port               :: inet:port_number(),
    base_path = <<>>   :: binary(),
    auth               :: {basic, binary()} | none,
    model              :: map() | undefined,
    buffer_max         :: pos_integer(),

    %% Permission handling
    permission_handler :: fun((binary(), map(), map()) ->
                               agent_wire:permission_result()) | undefined,

    %% Shared infrastructure
    sdk_mcp_registry   :: agent_wire_mcp:mcp_registry() | undefined,
    sdk_hook_registry  :: agent_wire_hooks:hook_registry() | undefined,
    %% Query span telemetry (monotonic start time)
    query_start_time   :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% Defaults
%%--------------------------------------------------------------------

-define(DEFAULT_BASE_URL, "http://localhost:4096").
-define(DEFAULT_BUFFER_MAX, 2 * 1024 * 1024).
-define(CONNECT_TIMEOUT, 15000).
-define(ERROR_STATE_TIMEOUT, 60000).
-define(SDK_VERSION, "0.1.0").

%%====================================================================
%% agent_wire_behaviour API
%%====================================================================

-doc "Start an OpenCode HTTP+SSE session as a linked gen_statem.".
-spec start_link(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-doc "Send a query prompt and return a message reference for collecting responses.".
-spec send_query(pid(), binary(), agent_wire:query_opts(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {send_query, Prompt, Params}, Timeout).

-doc "Receive the next message for the given query reference.".
-spec receive_message(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message(Pid, Ref, Timeout) ->
    gen_statem:call(Pid, {receive_message, Ref}, Timeout).

-doc "Return the current health state of the session.".
-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Pid) ->
    gen_statem:call(Pid, health, 5000).

-doc "Stop the session process.".
-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid, normal, 10000).

-doc "Send a control message. Not supported natively; use universal control.".
-spec send_control(pid(), binary(), map()) -> {error, not_supported}.
send_control(_Pid, _Method, _Params) ->
    {error, not_supported}.

-doc "Interrupt the current query by aborting it.".
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, abort, 10000).

-doc "Return session metadata (session id, directory, model, transport).".
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).

-doc "Change the model at runtime.".
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).

-doc "Set permission mode. Not supported natively; use universal control.".
-spec set_permission_mode(pid(), binary()) -> {ok, term()} | {error, term()}.
set_permission_mode(_Pid, _Mode) ->
    {error, not_supported}.

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(connecting) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    BaseUrl = maps:get(base_url, Opts, ?DEFAULT_BASE_URL),
    Directory = maps:get(directory, Opts, <<".">>),
    BufferMax = maps:get(buffer_max, Opts, ?DEFAULT_BUFFER_MAX),
    Model = maps:get(model, Opts, undefined),
    PermissionHandler = maps:get(permission_handler, Opts, undefined),
    McpRegistry = build_mcp_registry(Opts),
    HookRegistry = build_hook_registry(Opts),
    Auth = case maps:get(auth, Opts, none) of
        none -> none;
        {basic, U, P} -> opencode_http:encode_basic_auth(U, P);
        {basic, Encoded} when is_binary(Encoded) -> {basic, Encoded}
    end,
    {Host, Port, BasePath} = opencode_http:parse_base_url(BaseUrl),
    case gun:open(binary_to_list(Host), Port, #{protocols => [http]}) of
        {ok, ConnPid} ->
            MonRef = erlang:monitor(process, ConnPid),
            Data = #data{
                conn_pid           = ConnPid,
                conn_monitor       = MonRef,
                sse_state          = opencode_sse:new_state(),
                opts               = Opts,
                host               = Host,
                port               = Port,
                base_path          = BasePath,
                auth               = Auth,
                directory          = Directory,
                buffer_max         = BufferMax,
                model              = Model,
                permission_handler = PermissionHandler,
                sdk_mcp_registry   = McpRegistry,
                sdk_hook_registry  = HookRegistry,
                msg_queue          = queue:new()
            },
            {ok, connecting, Data};
        {error, Reason} ->
            {stop, {gun_open_failed, Reason}}
    end.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{conn_pid = ConnPid} = Data) ->
    _ = fire_hook(session_end, #{event => session_end, reason => Reason}, Data),
    close_gun(ConnPid),
    ok.

%%====================================================================
%% State: connecting
%%====================================================================

-spec connecting(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
connecting(enter, connecting, _Data) ->
    %% Initial entry from init/1
    agent_wire_telemetry:state_change(opencode, undefined, connecting),
    {keep_state_and_data, [{state_timeout, ?CONNECT_TIMEOUT, connect_timeout}]};

connecting(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(opencode, OldState, connecting),
    {keep_state_and_data, [{state_timeout, ?CONNECT_TIMEOUT, connect_timeout}]};

connecting(info, {gun_up, ConnPid, http}, #data{conn_pid = ConnPid} = Data) ->
    %% Connection established — open SSE stream immediately
    SsePath    = build_sse_path(Data),
    SseHeaders = build_sse_headers(Data),
    SseRef     = gun:get(ConnPid, SsePath, SseHeaders),
    {keep_state, Data#data{sse_ref = SseRef}};

connecting(info, {gun_response, ConnPid, SseRef, nofin, 200, _Headers},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    %% SSE stream opened successfully — wait for server.connected
    {keep_state, Data};

connecting(info, {gun_response, ConnPid, SseRef, _IsFin, Status, _Headers},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = _Data) ->
    logger:error("OpenCode SSE stream got unexpected status ~p in connecting", [Status]),
    {next_state, error, _Data,
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

connecting(info, {gun_data, ConnPid, SseRef, _IsFin, RawData},
           #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    %% SSE data arriving — parse and check for server.connected
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = Data#data{sse_state = NewSseState},
            case check_server_connected(Events) of
                true ->
                    {next_state, initializing, Data1};
                false ->
                    {keep_state, Data1}
            end;
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in connecting"),
            {next_state, error, Data,
             [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end;

connecting(state_timeout, connect_timeout, Data) ->
    logger:error("OpenCode connection timed out"),
    {next_state, error, Data,
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

connecting(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
           #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in connecting: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

connecting(info, {'DOWN', MonRef, process, ConnPid, Reason},
           #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in connecting: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

connecting(info, _UnexpectedMsg, _Data) ->
    %% Catch-all for unexpected info (e.g. gun_error) — ignore safely
    keep_state_and_data;

connecting({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, connecting}]};

connecting({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%%====================================================================
%% State: initializing
%%====================================================================

-spec initializing(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
initializing(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(opencode, OldState, initializing),
    %% POST /session to create (or reuse) a server-side session
    Body = build_session_create_body(Data),
    Data1 = post_json(<<"/session">>, Body, create_session, undefined, Data),
    {keep_state, Data1};

initializing(info, {gun_response, ConnPid, Ref, nofin, _Status, _Headers},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, From, _}} ->
            Pending1 = maps:put(Ref, {create_session, From, <<>>}, Pending),
            {keep_state, Data#data{rest_pending = Pending1}};
        _ ->
            {keep_state, Data}
    end;

initializing(info, {gun_data, ConnPid, Ref, fin, Body},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, _From, Acc}} ->
            FullBody = <<Acc/binary, (iolist_to_binary(Body))/binary>>,
            Pending1 = maps:remove(Ref, Pending),
            Data1 = Data#data{rest_pending = Pending1},
            case json:decode(FullBody) of
                SessionMap when is_map(SessionMap) ->
                    SessionId = maps:get(<<"id">>, SessionMap, undefined),
                    Data2 = Data1#data{session_id = SessionId},
                    _ = fire_hook(session_start,
                                  #{event => session_start,
                                    session_id => SessionId}, Data2),
                    {next_state, ready, Data2};
                _ ->
                    logger:error("OpenCode: failed to decode session create response"),
                    {next_state, error, Data1,
                     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
            end;
        _ ->
            {keep_state, Data}
    end;

initializing(info, {gun_data, ConnPid, Ref, nofin, Body},
             #data{conn_pid = ConnPid, rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        {ok, {create_session, From, Acc}} ->
            NewAcc = <<Acc/binary, (iolist_to_binary(Body))/binary>>,
            Pending1 = maps:put(Ref, {create_session, From, NewAcc}, Pending),
            {keep_state, Data#data{rest_pending = Pending1}};
        _ ->
            {keep_state, Data}
    end;

initializing(info, {gun_data, ConnPid, SseRef, _IsFin, RawData},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    %% Heartbeats and other SSE data during init — parse and ignore
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, _Events, NewSseState} ->
            {keep_state, Data#data{sse_state = NewSseState}};
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in initializing"),
            {next_state, error, Data,
             [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end;

initializing(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
             #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in initializing: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

initializing(info, {'DOWN', MonRef, process, ConnPid, Reason},
             #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in initializing: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
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
ready(enter, initializing, _Data) ->
    agent_wire_telemetry:state_change(opencode, initializing, ready),
    keep_state_and_data;

ready(enter, active_query, _Data) ->
    agent_wire_telemetry:state_change(opencode, active_query, ready),
    keep_state_and_data;

ready(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(opencode, OldState, ready),
    keep_state_and_data;

ready(info, {gun_data, ConnPid, SseRef, _IsFin, RawData},
     #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    %% SSE data in ready state — heartbeats, session updates, etc.
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, _Events, NewSseState} ->
            {keep_state, Data#data{sse_state = NewSseState}};
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in ready"),
            {next_state, error, Data,
             [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end;

ready({call, From}, {send_query, Prompt, Params}, Data) ->
    HookCtx = #{event => user_prompt_submit,
                prompt => Prompt, params => Params},
    case fire_hook(user_prompt_submit, HookCtx, Data) of
        {deny, Reason} ->
            {keep_state_and_data, [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_send_query(From, Prompt, Params, Data)
    end;

ready({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

ready({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};

ready({call, From}, {receive_message, Ref},
      #data{query_ref = Ref, msg_queue = Q} = Data) ->
    %% Drain remaining messages from a completed query
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            {keep_state, Data#data{query_ref = undefined, msg_queue = undefined},
             [{reply, From, {error, complete}}]}
    end;

ready({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

ready({call, From}, list_sessions, Data) ->
    Data1 = get_request(<<"/session">>, {list_sessions, From}, Data),
    {keep_state, Data1};

ready({call, From}, {get_session, Id}, Data) ->
    Path = <<"/session/", Id/binary>>,
    Data1 = get_request(Path, {get_session, From}, Data),
    {keep_state, Data1};

ready({call, From}, {delete_session, Id}, Data) ->
    Path = <<"/session/", Id/binary>>,
    Data1 = delete_request(Path, {delete_session, From}, Data),
    {keep_state, Data1};

ready({call, From}, {send_command, Command, Params}, Data) ->
    SessionId = Data#data.session_id,
    Path = <<"/session/", SessionId/binary, "/command">>,
    Body = Params#{<<"command">> => Command},
    Data1 = post_json(Path, Body, send_command, From, Data),
    {keep_state, Data1};

ready({call, From}, server_health, Data) ->
    Data1 = get_request(<<"/health">>, {server_health, From}, Data),
    {keep_state, Data1};

ready(info, {gun_response, ConnPid, Ref, IsFin, Status, _Headers},
     #data{conn_pid = ConnPid} = Data) ->
    handle_rest_response_headers(Ref, IsFin, Status, Data);

ready(info, {gun_data, ConnPid, Ref, IsFin, Body},
     #data{conn_pid = ConnPid} = Data) ->
    handle_rest_body(Ref, IsFin, Body, Data);

ready(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
     #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in ready: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

ready(info, {'DOWN', MonRef, process, ConnPid, Reason},
     #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in ready: ~p", [Reason]),
    {next_state, error, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

ready(info, _UnexpectedMsg, _Data) ->
    %% Catch-all for unexpected info (e.g. gun_error) — ignore safely
    keep_state_and_data;

ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.

%%====================================================================
%% State: active_query
%%====================================================================

-spec active_query(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
active_query(enter, ready, _Data) ->
    agent_wire_telemetry:state_change(opencode, ready, active_query),
    keep_state_and_data;

active_query(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(opencode, OldState, active_query),
    keep_state_and_data;

active_query(info, {gun_data, ConnPid, SseRef, _IsFin, RawData},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data) ->
    Bin = iolist_to_binary(RawData),
    case safe_parse_sse(Bin, Data) of
        {ok, Events, NewSseState} ->
            Data1 = Data#data{sse_state = NewSseState},
            dispatch_sse_events(Events, Data1);
        {error, buffer_overflow} ->
            logger:error("OpenCode SSE buffer overflow in active_query"),
            %% Enqueue error message for the waiting consumer
            ErrMsg = #{type => error,
                       content => <<"SSE buffer overflow">>,
                       subtype => <<"buffer_overflow">>},
            Q1 = queue:in(ErrMsg, Data#data.msg_queue),
            {next_state, error, Data#data{msg_queue = Q1},
             [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end;

active_query(info, {gun_response, ConnPid, Ref, IsFin, Status, _Headers},
             #data{conn_pid = ConnPid} = Data) ->
    handle_rest_response_headers(Ref, IsFin, Status, Data);

active_query(info, {gun_data, ConnPid, Ref, IsFin, Body},
             #data{conn_pid = ConnPid, sse_ref = SseRef} = Data)
  when Ref =/= SseRef ->
    handle_rest_body(Ref, IsFin, Body, Data);

active_query({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);

active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

active_query({call, From}, abort, Data) ->
    Data1 = do_abort(Data),
    {keep_state, Data1, [{reply, From, ok}]};

active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};

active_query({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

active_query({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};

active_query(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams},
             #data{conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun connection down in active_query: ~p", [Reason]),
    maybe_span_exception(Data, {gun_down, Reason}),
    ErrorMsg = #{type => error, content => <<"connection lost">>,
                 timestamp => erlang:system_time(millisecond)},
    Data1 = Data#data{conn_pid = undefined, sse_ref = undefined,
                      query_start_time = undefined},
    deliver_or_enqueue(ErrorMsg, Data1, fun(D) ->
        {next_state, error, D#data{consumer = undefined, query_ref = undefined},
         [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end);

active_query(info, {'DOWN', MonRef, process, ConnPid, Reason},
             #data{conn_monitor = MonRef, conn_pid = ConnPid} = Data) ->
    logger:error("OpenCode gun process crashed in active_query: ~p", [Reason]),
    maybe_span_exception(Data, {gun_crash, Reason}),
    ErrorMsg = #{type => error, content => <<"gun process crashed">>,
                 timestamp => erlang:system_time(millisecond)},
    Data1 = Data#data{conn_pid = undefined, sse_ref = undefined,
                      query_start_time = undefined},
    deliver_or_enqueue(ErrorMsg, Data1, fun(D) ->
        {next_state, error, D#data{consumer = undefined, query_ref = undefined},
         [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]}
    end);

active_query(info, _UnexpectedMsg, _Data) ->
    %% Catch-all for unexpected info (e.g. gun_error) — ignore safely
    keep_state_and_data;

active_query({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
error(enter, OldState, Data) ->
    agent_wire_telemetry:state_change(opencode, OldState, error),
    close_gun(Data#data.conn_pid),
    {keep_state, Data#data{conn_pid = undefined, sse_ref = undefined},
     [{state_timeout, ?ERROR_STATE_TIMEOUT, auto_stop}]};

error(state_timeout, auto_stop, _Data) ->
    {stop, normal};

error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};

error({call, From}, session_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, build_session_info(Data)}}]};

error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

%%====================================================================
%% Internal: Query dispatch
%%====================================================================

-spec do_send_query(gen_statem:from(), binary(), map(), #data{}) ->
    state_callback_result().
do_send_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime = agent_wire_telemetry:span_start(opencode, query, #{prompt => Prompt}),
    SessionId = Data#data.session_id,
    Path = <<"/session/", SessionId/binary, "/message">>,
    MergedOpts = case Data#data.model of
        undefined -> Params;
        Model -> maps:put(model, Model, Params)
    end,
    Body = opencode_protocol:build_prompt_input(Prompt, MergedOpts),
    Data1 = Data#data{
        consumer  = From,
        query_ref = Ref,
        msg_queue = queue:new(),
        query_start_time = StartTime
    },
    Data2 = post_json(Path, Body, send_message, undefined, Data1),
    {next_state, active_query, Data2, [{reply, From, {ok, Ref}}]}.

-spec do_abort(#data{}) -> #data{}.
do_abort(#data{session_id = SessionId} = Data) when SessionId =/= undefined ->
    Path = <<"/session/", SessionId/binary, "/abort">>,
    post_json(Path, #{}, abort_query, undefined, Data);
do_abort(Data) ->
    Data.

%%====================================================================
%% Internal: SSE event dispatch
%%====================================================================

-spec check_server_connected([opencode_sse:sse_event()]) -> boolean().
check_server_connected([]) -> false;
check_server_connected([#{event := <<"server.connected">>} | _]) -> true;
check_server_connected([_ | Rest]) -> check_server_connected(Rest).

-spec dispatch_sse_events([opencode_sse:sse_event()], #data{}) ->
    state_callback_result().
dispatch_sse_events([], Data) ->
    {keep_state, Data};
dispatch_sse_events([SseEvent | Rest], Data) ->
    %% Decode the JSON payload in the `data` field
    RawData = maps:get(data, SseEvent, <<>>),
    Payload = case RawData of
        <<>> -> #{};
        Json ->
            try json:decode(Json)
            catch _:_ -> #{}
            end
    end,
    EventMap = SseEvent#{data => Payload},
    case opencode_protocol:normalize_event(EventMap) of
        skip ->
            dispatch_sse_events(Rest, Data);
        #{type := control_request, request_id := PermId, request := Meta} = _Msg ->
            %% Permission request — handle synchronously and continue
            Data1 = handle_permission(PermId, Meta, Data),
            dispatch_sse_events(Rest, Data1);
        #{type := result} = ResultMsg ->
            %% session.idle — query complete, transition to ready
            maybe_span_stop(Data),
            _ = fire_hook(stop, #{event => stop, stop_reason => idle}, Data),
            deliver_or_enqueue(ResultMsg, Data, fun(D) ->
                {next_state, ready, D#data{consumer = undefined,
                                            query_start_time = undefined}}
            end);
        #{type := error} = ErrMsg ->
            %% session.error — query failed
            maybe_span_exception(Data, session_error),
            deliver_or_enqueue(ErrMsg, Data, fun(D) ->
                {next_state, ready, D#data{consumer = undefined,
                                            query_start_time = undefined}}
            end);
        Msg ->
            deliver_or_enqueue(Msg, Data, fun(D) ->
                dispatch_sse_events(Rest, D)
            end)
    end.

%%====================================================================
%% Internal: Permission handling (FAIL-CLOSED)
%%====================================================================

-spec handle_permission(binary(), map(), #data{}) -> #data{}.
handle_permission(PermId, Metadata, Data) ->
    Decision = case Data#data.permission_handler of
        undefined ->
            <<"deny">>;
        Handler ->
            try Handler(PermId, Metadata, #{}) of
                {allow, _} -> <<"allow">>;
                {allow, _, _} -> <<"allow">>;
                {deny, _}  -> <<"deny">>;
                _Other     -> <<"deny">>
            catch _:_ ->
                <<"deny">>
            end
    end,
    Body = opencode_protocol:build_permission_reply(PermId, Decision),
    Path = <<"/permission/", PermId/binary, "/reply">>,
    post_json(Path, Body, permission_reply, undefined, Data).

%%====================================================================
%% Internal: REST request helpers
%%====================================================================

-spec post_json(binary(), map(), rest_purpose(),
                gen_statem:from() | undefined, #data{}) -> #data{}.
post_json(EndpointPath, Body, Purpose, From, Data) ->
    FullPath = opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers  = opencode_http:common_headers(Data#data.auth, Data#data.directory),
    Encoded  = json:encode(Body),
    Ref      = gun:post(Data#data.conn_pid, binary_to_list(FullPath), Headers, Encoded),
    Pending  = maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.

-spec get_request(binary(), {rest_purpose(), gen_statem:from()}, #data{}) -> #data{}.
get_request(EndpointPath, {Purpose, From}, Data) ->
    FullPath = opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers  = opencode_http:common_headers(Data#data.auth, Data#data.directory),
    Ref      = gun:get(Data#data.conn_pid, binary_to_list(FullPath), Headers),
    Pending  = maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.

-spec delete_request(binary(), {rest_purpose(), gen_statem:from()}, #data{}) -> #data{}.
delete_request(EndpointPath, {Purpose, From}, Data) ->
    FullPath = opencode_http:build_path(Data#data.base_path, EndpointPath),
    Headers  = opencode_http:common_headers(Data#data.auth, Data#data.directory),
    Ref      = gun:delete(Data#data.conn_pid, binary_to_list(FullPath), Headers),
    Pending  = maps:put(Ref, {Purpose, From, <<>>}, Data#data.rest_pending),
    Data#data{rest_pending = Pending}.

%%====================================================================
%% Internal: REST response handling
%%====================================================================

-spec handle_rest_response_headers(reference(), fin | nofin, integer(), #data{}) ->
    state_callback_result().
handle_rest_response_headers(Ref, IsFin, _Status, #data{rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        error ->
            {keep_state, Data};
        {ok, {Purpose, From, Acc}} ->
            case IsFin of
                fin ->
                    %% Headers only, no body — complete immediately
                    Pending1 = maps:remove(Ref, Pending),
                    handle_rest_complete(Purpose, From, Acc,
                                        Data#data{rest_pending = Pending1});
                nofin ->
                    {keep_state, Data}
            end
    end.

-spec handle_rest_body(reference(), fin | nofin, iodata(), #data{}) ->
    state_callback_result().
handle_rest_body(Ref, IsFin, Body, #data{rest_pending = Pending} = Data) ->
    case maps:find(Ref, Pending) of
        error ->
            {keep_state, Data};
        {ok, {Purpose, From, Acc}} ->
            NewAcc = <<Acc/binary, (iolist_to_binary(Body))/binary>>,
            case IsFin of
                nofin ->
                    Pending1 = maps:put(Ref, {Purpose, From, NewAcc}, Pending),
                    {keep_state, Data#data{rest_pending = Pending1}};
                fin ->
                    Pending1 = maps:remove(Ref, Pending),
                    handle_rest_complete(Purpose, From, NewAcc,
                                        Data#data{rest_pending = Pending1})
            end
    end.

-spec handle_rest_complete(rest_purpose(), gen_statem:from() | undefined,
                            binary(), #data{}) -> state_callback_result().
handle_rest_complete(create_session, _From, Body, Data) ->
    %% Should not arrive here during normal flow (handled in initializing),
    %% but guard defensively.
    case json:decode(Body) of
        SessionMap when is_map(SessionMap) ->
            SessionId = maps:get(<<"id">>, SessionMap, Data#data.session_id),
            {keep_state, Data#data{session_id = SessionId}};
        _ ->
            {keep_state, Data}
    end;

handle_rest_complete(send_message, _From, _Body, Data) ->
    %% Message POST acknowledged — response arrives via SSE stream
    {keep_state, Data};

handle_rest_complete(abort_query, _From, _Body, Data) ->
    %% Abort acknowledged — remain in current state, session.idle will arrive
    {keep_state, Data};

handle_rest_complete(permission_reply, _From, _Body, Data) ->
    {keep_state, Data};

handle_rest_complete(list_sessions, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};

handle_rest_complete(get_session, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};

handle_rest_complete(delete_session, From, _Body, Data) ->
    maybe_reply(From, {ok, deleted}),
    {keep_state, Data};

handle_rest_complete(send_command, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data};

handle_rest_complete(server_health, From, Body, Data) ->
    Result = decode_json_result(Body),
    maybe_reply(From, Result),
    {keep_state, Data}.

-spec decode_json_result(binary()) -> {ok, term()} | {error, decode_failed}.
decode_json_result(<<>>) -> {ok, #{}};
decode_json_result(Body) ->
    try {ok, json:decode(Body)}
    catch _:_ -> {error, decode_failed}
    end.

-spec maybe_reply(gen_statem:from() | undefined, term()) -> ok.
maybe_reply(undefined, _Result) -> ok;
maybe_reply(From, Result) ->
    gen_statem:reply(From, Result).

%%====================================================================
%% Internal: Message delivery
%%====================================================================

-spec try_deliver_message(gen_statem:from(), #data{}) -> state_callback_result().
try_deliver_message(From, #data{msg_queue = Q} = Data) ->
    case queue:out(Q) of
        {{value, Msg}, Q1} ->
            {keep_state, Data#data{msg_queue = Q1},
             [{reply, From, {ok, Msg}}]};
        {empty, _} ->
            %% No message yet — store consumer, wait for SSE data
            {keep_state, Data#data{consumer = From}}
    end.

-spec deliver_or_enqueue(agent_wire:message(), #data{},
                          fun((#data{}) -> state_callback_result())) ->
    state_callback_result().
deliver_or_enqueue(Msg, #data{consumer = undefined, msg_queue = Q} = Data, Continue) ->
    Q1 = queue:in(Msg, Q),
    Continue(Data#data{msg_queue = Q1});
deliver_or_enqueue(Msg, #data{consumer = From} = Data, Continue) ->
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
%% Internal: Hook firing
%%====================================================================

-spec fire_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_context(),
                #data{}) -> ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    agent_wire_hooks:fire(Event, Context, Registry).

%%====================================================================
%% Internal: SSE path and headers
%%====================================================================

-spec build_sse_path(#data{}) -> string().
build_sse_path(#data{base_path = Base}) ->
    binary_to_list(<<Base/binary, "/events">>).

-spec build_sse_headers(#data{}) -> [{binary(), binary()}].
build_sse_headers(#data{auth = Auth, directory = Dir}) ->
    [
        {<<"accept">>,               <<"text/event-stream">>},
        {<<"cache-control">>,        <<"no-cache">>},
        {<<"x-opencode-directory">>, Dir}
        | opencode_http:auth_headers(Auth)
    ].

%%====================================================================
%% Internal: Session management
%%====================================================================

-spec build_session_create_body(#data{}) -> map().
build_session_create_body(#data{opts = Opts, directory = Dir}) ->
    Base = #{<<"directory">> => Dir},
    case maps:get(model, Opts, undefined) of
        undefined -> Base;
        Model when is_map(Model) -> Base#{<<"model">> => Model};
        Model when is_binary(Model) -> Base#{<<"model">> => Model};
        _ -> Base
    end.

-spec build_session_info(#data{}) -> map().
build_session_info(Data) ->
    #{session_id => Data#data.session_id,
      directory  => Data#data.directory,
      model      => Data#data.model,
      host       => Data#data.host,
      port       => Data#data.port,
      transport  => http}.

%%====================================================================
%% Internal: Gun connection management
%%====================================================================

%%====================================================================
%% Internal: SSE buffer safety
%%====================================================================

%% Parse SSE data with buffer overflow protection.
%% Returns `{ok, Events, NewSseState}` on success, or
%% `{error, buffer_overflow}` if the SSE buffer exceeds buffer_max.
-spec safe_parse_sse(binary(), #data{}) ->
    {ok, [opencode_sse:sse_event()], opencode_sse:parse_state()} |
    {error, buffer_overflow}.
safe_parse_sse(Bin, #data{sse_state = SseState, buffer_max = BufferMax}) ->
    %% Check current buffer + incoming data won't exceed limit
    CurrentSize = opencode_sse:buffer_size(SseState),
    IncomingSize = byte_size(Bin),
    case CurrentSize + IncomingSize > BufferMax of
        true ->
            agent_wire_telemetry:buffer_overflow(
                CurrentSize + IncomingSize, BufferMax),
            {error, buffer_overflow};
        false ->
            {Events, NewState} = opencode_sse:parse_chunk(Bin, SseState),
            {ok, Events, NewState}
    end.

%%====================================================================
%% Internal: Gun connection management
%%====================================================================

-spec close_gun(pid() | undefined) -> ok.
close_gun(undefined) -> ok;
close_gun(ConnPid) ->
    try gun:close(ConnPid) catch _:_ -> ok end,
    ok.

%%====================================================================
%% Internal: Registry building
%%====================================================================

%% Build an MCP registry from the sdk_mcp_servers option.
%% Stored for API parity. OpenCode (HTTP/SSE) does not currently
%% support in-process tool dispatch — no callback protocol from server.
-spec build_mcp_registry(map()) -> agent_wire_mcp:mcp_registry() | undefined.
build_mcp_registry(Opts) ->
    agent_wire_mcp:build_registry(maps:get(sdk_mcp_servers, Opts, undefined)).

-spec build_hook_registry(map()) -> agent_wire_hooks:hook_registry() | undefined.
build_hook_registry(Opts) ->
    agent_wire_hooks:build_registry(maps:get(sdk_hooks, Opts, undefined)).

%%====================================================================
%% Internal: Telemetry Span Helpers
%%====================================================================

-spec maybe_span_stop(#data{}) -> ok.
maybe_span_stop(#data{query_start_time = undefined}) -> ok;
maybe_span_stop(#data{query_start_time = StartTime}) ->
    agent_wire_telemetry:span_stop(opencode, query, StartTime).

-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) -> ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    agent_wire_telemetry:span_exception(opencode, query, Reason).
