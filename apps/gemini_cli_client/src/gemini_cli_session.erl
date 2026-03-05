%%%-------------------------------------------------------------------
%%% @doc Gemini CLI adapter — gen_statem for one-shot queries.
%%%
%%% Port/JSONL-based adapter using `gemini --prompt PROMPT
%%% --output-format stream-json'. Each query spawns a new port process.
%%% No initialize handshake, no thread management, no approval callbacks.
%%% Session IDs are captured from init events and reused via --resume
%%% on subsequent queries within the same session process.
%%%
%%% State machine:
%%%   idle -> active_query -> idle -> ...
%%%                |
%%%                +-> error
%%%
%%% Implements agent_wire_behaviour for unified consumer API.
%%% @end
%%%-------------------------------------------------------------------
-module(gemini_cli_session).

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
    idle/3,
    active_query/3,
    error/3
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type state_name() :: idle | active_query | error.

-type state_callback_result() ::
    gen_statem:state_enter_result(state_name()) |
    gen_statem:event_handler_result(state_name()).

-export_type([state_name/0]).

-dialyzer({no_underspecs, [build_cli_args/2, build_port_opts/3]}).

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(data, {
    %% Port (created per query)
    port               :: port() | undefined,
    buffer = <<>>      :: binary(),
    buffer_max         :: pos_integer(),

    %% Consumer demand
    consumer           :: gen_statem:from() | undefined,
    query_ref          :: reference() | undefined,
    msg_queue          :: queue:queue() | undefined,

    %% Session continuity (captured from init events, reused via --resume)
    session_id         :: binary() | undefined,

    %% Configuration
    opts               :: map(),
    cli_path           :: string(),
    model              :: binary() | undefined,
    approval_mode      :: binary() | undefined,

    %% Shared infrastructure
    sdk_mcp_registry   :: agent_wire_mcp:mcp_registry() | undefined,
    sdk_hook_registry  :: agent_wire_hooks:hook_registry() | undefined,
    %% Query span telemetry (monotonic start time)
    query_start_time   :: integer() | undefined
}).

%%--------------------------------------------------------------------
%% Defaults
%%--------------------------------------------------------------------

-define(DEFAULT_BUFFER_MAX, 2 * 1024 * 1024).
-define(DEFAULT_CLI, "gemini").
-define(SDK_VERSION, "beam-0.1.0").

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

-spec send_control(pid(), binary(), map()) -> {error, not_supported}.
send_control(_Pid, _Method, _Params) ->
    {error, not_supported}.

-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Pid) ->
    gen_statem:call(Pid, interrupt, 5000).

-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Pid) ->
    gen_statem:call(Pid, session_info, 5000).

-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Pid, Model) ->
    gen_statem:call(Pid, {set_model, Model}, 5000).

-spec set_permission_mode(pid(), binary()) -> {error, not_supported}.
set_permission_mode(_Pid, _Mode) ->
    {error, not_supported}.

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> [state_functions | state_enter, ...].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(idle) | {stop, term()}.
init(Opts) ->
    process_flag(trap_exit, true),
    CliPath = maps:get(cli_path, Opts, os:getenv("GEMINI_CLI_PATH", ?DEFAULT_CLI)),
    BufferMax = maps:get(buffer_max, Opts, ?DEFAULT_BUFFER_MAX),
    Model = maps:get(model, Opts, undefined),
    ApprovalMode = case maps:get(approval_mode, Opts, undefined) of
        undefined -> undefined;
        AM when is_atom(AM) -> atom_to_binary(AM, utf8);
        AM when is_binary(AM) -> AM
    end,
    McpRegistry = build_mcp_registry(Opts),
    HookRegistry = build_hook_registry(Opts),
    Data = #data{
        opts = Opts,
        cli_path = CliPath,
        buffer_max = BufferMax,
        model = Model,
        approval_mode = ApprovalMode,
        sdk_mcp_registry = McpRegistry,
        sdk_hook_registry = HookRegistry
    },
    {ok, idle, Data}.

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(Reason, _State, #data{port = Port} = Data) ->
    %% Fire session_end hook (consistent with codex_exec)
    _ = fire_hook(session_end, #{event => session_end, reason => Reason}, Data),
    close_port(Port),
    ok.

%%====================================================================
%% State: idle (ready for queries)
%%====================================================================

-spec idle(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
idle(enter, idle, _Data) ->
    %% Initial entry from init/1
    agent_wire_telemetry:state_change(gemini, undefined, idle),
    keep_state_and_data;

idle(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(gemini, OldState, idle),
    keep_state_and_data;

idle({call, From}, {send_query, Prompt, Params}, Data) ->
    %% Fire user_prompt_submit hook
    HookCtx = #{event => user_prompt_submit,
                prompt => Prompt, params => Params},
    case agent_wire_hooks:fire(user_prompt_submit, HookCtx, Data#data.sdk_hook_registry) of
        {deny, Reason} ->
            {keep_state_and_data, [{reply, From, {error, {hook_denied, Reason}}}]};
        ok ->
            do_exec_query(From, Prompt, Params, Data)
    end;

idle({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

idle({call, From}, session_info, Data) ->
    Info = #{session_id    => Data#data.session_id,
             model         => Data#data.model,
             approval_mode => Data#data.approval_mode,
             transport     => gemini_cli},
    {keep_state_and_data, [{reply, From, {ok, Info}}]};

idle({call, From}, {set_model, Model}, Data) ->
    {keep_state, Data#data{model = Model}, [{reply, From, {ok, Model}}]};

idle({call, From}, {set_permission_mode, _Mode}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};

idle(info, {'EXIT', _Port, _Reason}, _Data) ->
    %% Port process exit after we already handled exit_status
    keep_state_and_data;

idle({call, From}, {send_control, _Method, _Params}, _Data) ->
    %% Gemini CLI session does not support control messages
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};

idle({call, From}, interrupt, _Data) ->
    %% Nothing to interrupt in idle state
    {keep_state_and_data, [{reply, From, {error, no_active_query}}]};

idle({call, From}, {receive_message, Ref}, #data{query_ref = Ref, msg_queue = Q} = Data) ->
    %% Drain remaining messages from a completed query
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

idle({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

idle({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_request}}]}.

%%====================================================================
%% State: active_query
%%====================================================================

-spec active_query(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
active_query(enter, idle, _Data) ->
    agent_wire_telemetry:state_change(gemini, idle, active_query),
    keep_state_and_data;

active_query(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(gemini, OldState, active_query),
    keep_state_and_data;

active_query(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    Data1 = buffer_line(Line, Data),
    process_query_buffer(Data1);

active_query(info, {Port, {data, {noeol, Partial}}}, #data{port = Port} = Data) ->
    {keep_state, append_buffer(Partial, Data)};

active_query(info, {Port, {exit_status, 0}}, #data{port = Port} = Data) ->
    %% Normal completion — drain buffer and signal complete
    Data1 = Data#data{port = undefined},
    drain_and_complete(Data1);

active_query(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    %% Abnormal exit — map exit code to error reason
    maybe_span_exception(Data, {cli_exit, Status}),
    Data1 = Data#data{port = undefined, query_start_time = undefined},
    Reason = gemini_cli_protocol:exit_code_to_error(Status),
    ErrorMsg = #{type => error,
                 content => iolist_to_binary(
                     io_lib:format("gemini cli exited with status ~p (~s)",
                                   [Status, Reason])),
                 timestamp => erlang:system_time(millisecond)},
    deliver_or_enqueue(ErrorMsg, Data1, fun(D) ->
        {next_state, idle, D#data{consumer = undefined, query_ref = undefined}}
    end);

active_query({call, From}, {receive_message, Ref}, #data{query_ref = Ref} = Data) ->
    try_deliver_message(From, Data);

active_query({call, From}, {receive_message, _WrongRef}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, bad_ref}}]};

active_query({call, From}, {send_query, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]};

active_query({call, From}, interrupt, Data) ->
    close_port(Data#data.port),
    Data1 = Data#data{port = undefined},
    {next_state, idle, Data1#data{consumer = undefined, query_ref = undefined},
     [{reply, From, ok}]};

active_query(info, {'EXIT', _Port, _Reason}, _Data) ->
    %% Port process exit after we already handled exit_status
    keep_state_and_data;

active_query({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, active_query}]};

active_query({call, From}, session_info, Data) ->
    Info = #{session_id    => Data#data.session_id,
             model         => Data#data.model,
             approval_mode => Data#data.approval_mode,
             transport     => gemini_cli},
    {keep_state_and_data, [{reply, From, {ok, Info}}]};

active_query({call, From}, {send_control, _Method, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_supported}}]};

active_query({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, query_in_progress}}]}.

%%====================================================================
%% State: error
%%====================================================================

-spec error(gen_statem:event_type(), term(), #data{}) -> state_callback_result().
error(enter, OldState, _Data) ->
    agent_wire_telemetry:state_change(gemini, OldState, error),
    %% Auto-stop after 60 seconds in error state
    {keep_state_and_data, [{state_timeout, 60000, auto_stop}]};

error(state_timeout, auto_stop, Data) ->
    {stop, normal, Data};

error({call, From}, health, _Data) ->
    {keep_state_and_data, [{reply, From, error}]};

error({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, session_error}}]}.

%%====================================================================
%% Internal: Query Dispatch
%%====================================================================

-spec do_exec_query(gen_statem:from(), binary(), map(), #data{}) ->
    state_callback_result().
do_exec_query(From, Prompt, Params, Data) ->
    Ref = make_ref(),
    StartTime = agent_wire_telemetry:span_start(gemini, query, #{prompt => Prompt}),
    Model = maps:get(model, Params, Data#data.model),
    AM = maps:get(approval_mode, Params, Data#data.approval_mode),
    try
        {CliPath, PortOpts} = build_port_opts(Data#data.cli_path, Prompt,
                                              #{model => Model,
                                                approval_mode => AM,
                                                session_id => Data#data.session_id,
                                                env => maps:get(env, Data#data.opts, [])}),
        Port = open_port({spawn_executable, CliPath}, PortOpts),
        Data1 = Data#data{
            port = Port,
            buffer = <<>>,
            consumer = From,
            query_ref = Ref,
            msg_queue = queue:new(),
            query_start_time = StartTime
        },
        {next_state, active_query, Data1, [{reply, From, {ok, Ref}}]}
    catch
        error:Reason ->
            agent_wire_telemetry:span_exception(gemini, query,
                                                {open_port_failed, Reason}),
            {keep_state_and_data, [{reply, From, {error, {open_port_failed, Reason}}}]}
    end.

%%====================================================================
%% Internal: Port Management
%%====================================================================

-spec build_port_opts(string(), binary(), map()) -> {string(), list()}.
build_port_opts(CliPath, Prompt, Opts) ->
    UserEnv = maps:get(env, Opts, []),
    Env = [{"GEMINI_CLI_SDK_VERSION", ?SDK_VERSION},
           {"NO_COLOR", "1"}] ++ UserEnv,
    Args = build_cli_args(Prompt, Opts),
    {CliPath, [{args, Args}, {line, 65536}, binary, exit_status, use_stdio,
               {env, Env}]}.

-spec build_cli_args(binary(), map()) -> [string()].
build_cli_args(Prompt, Opts) ->
    Base = ["--prompt", binary_to_list(Prompt),
            "--output-format", "stream-json"],
    WithModel = case maps:get(model, Opts, undefined) of
        undefined -> Base;
        Model when is_binary(Model) -> Base ++ ["--model", binary_to_list(Model)]
    end,
    WithApproval = case maps:get(approval_mode, Opts, undefined) of
        undefined -> WithModel;
        AM when is_binary(AM) -> WithModel ++ ["--approval-mode", binary_to_list(AM)]
    end,
    WithOutputSchema = case maps:get(output_format, Opts, undefined) of
        undefined -> WithApproval;
        Schema when is_map(Schema) ->
            JsonBin = iolist_to_binary(json:encode(Schema)),
            WithApproval ++ ["--output-schema", binary_to_list(JsonBin)]
    end,
    case maps:get(session_id, Opts, undefined) of
        undefined -> WithOutputSchema;
        SessionId when is_binary(SessionId), byte_size(SessionId) > 0 ->
            WithOutputSchema ++ ["--resume", binary_to_list(SessionId)];
        _ -> WithOutputSchema
    end.

%%====================================================================
%% Internal: Buffer Management (inline — does not depend on codex_port_utils)
%%====================================================================

-spec buffer_line(binary(), #data{}) -> #data{}.
buffer_line(Line, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = check_buffer_overflow(
        <<Buffer/binary, Line/binary, "\n">>, Max)}.

-spec append_buffer(binary(), #data{}) -> #data{}.
append_buffer(Partial, #data{buffer = Buffer, buffer_max = Max} = Data) ->
    Data#data{buffer = check_buffer_overflow(
        <<Buffer/binary, Partial/binary>>, Max)}.

-spec check_buffer_overflow(binary(), pos_integer()) -> binary().
check_buffer_overflow(Buffer, BufferMax) ->
    case byte_size(Buffer) > BufferMax of
        true ->
            agent_wire_telemetry:buffer_overflow(byte_size(Buffer), BufferMax),
            logger:warning("Gemini CLI buffer overflow (~p bytes), truncating",
                           [byte_size(Buffer)]),
            <<>>;
        false ->
            Buffer
    end.

%%====================================================================
%% Internal: Buffer Processing
%%====================================================================

-spec process_query_buffer(#data{}) -> state_callback_result().
process_query_buffer(Data) ->
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            {keep_state, Data};
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case agent_wire_jsonl:decode_line(Line) of
                {ok, Map} ->
                    %% Normalize to agent_wire:message() via Gemini protocol
                    Msg = gemini_cli_protocol:normalize_event(Map),
                    %% Capture session_id from init events
                    Data2 = maybe_capture_session_id(Msg, Data1),
                    %% Fire session_start hook on init event
                    Data3 = maybe_fire_session_start(Msg, Data2),
                    %% Fire post_tool_use hook on tool_result events
                    _ = maybe_fire_post_tool_use(Msg, Data3),
                    %% Span stop on result events
                    _ = maybe_span_stop_on_result(Msg, Data3),
                    %% Fire stop hook on result events
                    _ = maybe_fire_stop(Msg, Data3),
                    deliver_or_enqueue(Msg, Data3, fun(D) ->
                        process_query_buffer(D)
                    end);
                {error, _} ->
                    process_query_buffer(Data1)
            end
    end.

-spec drain_and_complete(#data{}) -> state_callback_result().
drain_and_complete(Data) ->
    %% Process any remaining buffer
    case agent_wire_jsonl:extract_line(Data#data.buffer) of
        none ->
            %% No more data — signal completion
            %% Keep query_ref so consumer can drain remaining queued messages
            case Data#data.consumer of
                undefined ->
                    {next_state, idle, Data#data{query_start_time = undefined}};
                From ->
                    {next_state, idle,
                     Data#data{consumer = undefined, query_start_time = undefined},
                     [{reply, From, {error, complete}}]}
            end;
        {ok, Line, Rest} ->
            Data1 = Data#data{buffer = Rest},
            case agent_wire_jsonl:decode_line(Line) of
                {ok, Map} ->
                    Msg = gemini_cli_protocol:normalize_event(Map),
                    Data2 = maybe_capture_session_id(Msg, Data1),
                    Data3 = maybe_fire_session_start(Msg, Data2),
                    _ = maybe_fire_post_tool_use(Msg, Data3),
                    _ = maybe_span_stop_on_result(Msg, Data3),
                    _ = maybe_fire_stop(Msg, Data3),
                    deliver_or_enqueue(Msg, Data3, fun(D) ->
                        drain_and_complete(D)
                    end);
                {error, _} ->
                    drain_and_complete(Data1)
            end
    end.

%%====================================================================
%% Internal: Session ID Capture
%%====================================================================

-spec maybe_capture_session_id(agent_wire:message(), #data{}) -> #data{}.
maybe_capture_session_id(#{type := system, subtype := <<"init">>,
                           session_id := SessionId}, Data)
  when is_binary(SessionId), byte_size(SessionId) > 0 ->
    Data#data{session_id = SessionId};
maybe_capture_session_id(_Msg, Data) ->
    Data.

%%====================================================================
%% Internal: Hook Firing
%%====================================================================

-spec maybe_fire_session_start(agent_wire:message(), #data{}) -> #data{}.
maybe_fire_session_start(#{type := system, subtype := <<"init">>} = Msg, Data) ->
    HookCtx = #{event => session_start,
                session_id => maps:get(session_id, Msg, <<>>),
                system_info => #{}},
    _ = fire_hook(session_start, HookCtx, Data),
    Data;
maybe_fire_session_start(_Msg, Data) ->
    Data.

-spec maybe_fire_post_tool_use(agent_wire:message(), #data{}) -> ok.
maybe_fire_post_tool_use(#{type := tool_result} = Msg, Data) ->
    HookCtx = #{event => post_tool_use,
                tool_use_id => maps:get(tool_use_id, Msg, <<>>),
                content => maps:get(content, Msg, <<>>)},
    _ = fire_hook(post_tool_use, HookCtx, Data),
    ok;
maybe_fire_post_tool_use(_Msg, _Data) ->
    ok.

-spec maybe_fire_stop(agent_wire:message(), #data{}) -> ok.
maybe_fire_stop(#{type := result} = Msg, Data) ->
    Stats = maps:get(stats, Msg, #{}),
    HookCtx = #{event => stop,
                duration_ms => maps:get(duration_ms, Stats, 0)},
    _ = fire_hook(stop, HookCtx, Data),
    ok;
maybe_fire_stop(_Msg, _Data) ->
    ok.

-spec fire_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_context(),
                #data{}) -> ok | {deny, binary()}.
fire_hook(Event, Context, #data{sdk_hook_registry = Registry}) ->
    agent_wire_hooks:fire(Event, Context, Registry).

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
            %% No message available — store consumer and wait
            Data1 = Data#data{consumer = From},
            case Data1#data.port of
                undefined ->
                    %% Port gone — complete
                    {next_state, idle,
                     Data1#data{consumer = undefined, query_ref = undefined},
                     [{reply, From, {error, complete}}]};
                _ ->
                    %% Wait for more data
                    {keep_state, Data1}
            end
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
%% Internal: Port Close
%%====================================================================

-spec close_port(port() | undefined) -> ok.
close_port(undefined) -> ok;
close_port(Port) ->
    try port_close(Port) catch error:_ -> ok end,
    ok.

%%====================================================================
%% Internal: MCP + Hook Registry Building
%%====================================================================

%% @doc Build an MCP registry from the sdk_mcp_servers option.
%%      Stored for API parity. Gemini CLI (unidirectional Port/JSONL)
%%      does not support in-process tool dispatch — no callback protocol.
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
    agent_wire_telemetry:span_stop(gemini, query, StartTime).

-spec maybe_span_exception(#data{}, term()) -> ok.
maybe_span_exception(#data{query_start_time = undefined}, _Reason) -> ok;
maybe_span_exception(#data{query_start_time = _StartTime}, Reason) ->
    agent_wire_telemetry:span_exception(gemini, query, Reason).

-spec maybe_span_stop_on_result(agent_wire:message(), #data{}) -> ok.
maybe_span_stop_on_result(#{type := result}, Data) ->
    maybe_span_stop(Data);
maybe_span_stop_on_result(_, _Data) ->
    ok.
