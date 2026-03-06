-module(agent_wire_control).
-moduledoc """
Universal session control protocol for the BEAM Agent SDK.

Provides session-scoped configuration state, task tracking,
feedback management, and turn response handling. Implements a
virtual control protocol for adapters without native control
message support.

Uses ETS for per-session state. All state is keyed by session_id
and persists for the node lifetime or until explicitly cleared.

Usage:
```erlang
%% Set session config:
agent_wire_control:set_permission_mode(SessionId, <<"acceptEdits">>),
agent_wire_control:set_max_thinking_tokens(SessionId, 8192),

%% Dispatch a control method:
{ok, _} = agent_wire_control:dispatch(SessionId, <<"setModel">>,
    #{<<"model">> => <<"claude-sonnet-4-6">>}),

%% Track tasks:
agent_wire_control:register_task(SessionId, TaskId, Pid),
agent_wire_control:stop_task(SessionId, TaskId),

%% Submit feedback:
agent_wire_control:submit_feedback(SessionId, #{rating => good}),

%% Turn response:
agent_wire_control:store_pending_request(SessionId, ReqId, Request),
agent_wire_control:resolve_pending_request(SessionId, ReqId, Response)
```
""".

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Control dispatch
    dispatch/3,
    %% Session config
    get_config/2,
    set_config/3,
    get_all_config/1,
    clear_config/1,
    %% Permission mode
    set_permission_mode/2,
    get_permission_mode/1,
    %% Thinking tokens
    set_max_thinking_tokens/2,
    get_max_thinking_tokens/1,
    %% Task tracking
    register_task/3,
    unregister_task/2,
    stop_task/2,
    list_tasks/1,
    %% Feedback
    submit_feedback/2,
    get_feedback/1,
    clear_feedback/1,
    %% Turn response
    store_pending_request/3,
    resolve_pending_request/3,
    get_pending_response/2,
    list_pending_requests/1
]).

-export_type([task_meta/0, pending_request/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type task_meta() :: #{
    task_id := binary(),
    session_id := binary(),
    pid := pid(),
    started_at := integer(),
    status := running | stopped
}.

-type pending_request() :: #{
    request_id := binary(),
    session_id := binary(),
    request := map(),
    status := pending | resolved,
    response => map(),
    created_at := integer(),
    resolved_at => integer()
}.

%% ETS tables.
-define(CONFIG_TABLE, agent_wire_control_config).
-define(TASKS_TABLE, agent_wire_control_tasks).
-define(FEEDBACK_TABLE, agent_wire_control_feedback).
-define(PENDING_TABLE, agent_wire_control_pending).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

-doc "Ensure all control ETS tables exist. Idempotent.".
-spec ensure_tables() -> ok.
ensure_tables() ->
    ensure_ets(?CONFIG_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_ets(?TASKS_TABLE, [set, public, named_table]),
    ensure_ets(?FEEDBACK_TABLE, [ordered_set, public, named_table]),
    ensure_ets(?PENDING_TABLE, [set, public, named_table]),
    ok.

-doc "Clear all control state.".
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    ets:delete_all_objects(?CONFIG_TABLE),
    ets:delete_all_objects(?TASKS_TABLE),
    ets:delete_all_objects(?FEEDBACK_TABLE),
    ets:delete_all_objects(?PENDING_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Control Dispatch
%%--------------------------------------------------------------------

-doc """
Dispatch a control method to the appropriate handler.
Known methods are handled internally; unknown methods return error.
""".
-spec dispatch(binary(), binary(), map()) ->
    {ok, term()} | {error, term()}.
dispatch(SessionId, Method, Params)
  when is_binary(SessionId), is_binary(Method), is_map(Params) ->
    case Method of
        <<"setModel">> ->
            Model = maps:get(<<"model">>, Params,
                maps:get(model, Params, undefined)),
            case Model of
                undefined -> {error, {missing_param, model}};
                M -> set_config(SessionId, model, M), {ok, #{model => M}}
            end;
        <<"setPermissionMode">> ->
            Mode = maps:get(<<"permissionMode">>, Params,
                maps:get(permission_mode, Params, undefined)),
            case Mode of
                undefined -> {error, {missing_param, permission_mode}};
                M -> set_permission_mode(SessionId, M), {ok, #{permission_mode => M}}
            end;
        <<"setMaxThinkingTokens">> ->
            Tokens = maps:get(<<"maxThinkingTokens">>, Params,
                maps:get(max_thinking_tokens, Params, undefined)),
            case Tokens of
                undefined -> {error, {missing_param, max_thinking_tokens}};
                T when is_integer(T), T > 0 ->
                    set_max_thinking_tokens(SessionId, T),
                    {ok, #{max_thinking_tokens => T}};
                _ -> {error, {invalid_param, max_thinking_tokens}}
            end;
        <<"stopTask">> ->
            TaskId = maps:get(<<"taskId">>, Params,
                maps:get(task_id, Params, undefined)),
            case TaskId of
                undefined -> {error, {missing_param, task_id}};
                TId -> stop_task(SessionId, TId)
            end;
        _ ->
            {error, {unknown_method, Method}}
    end.

%%--------------------------------------------------------------------
%% Session Config
%%--------------------------------------------------------------------

-doc "Get a config value for a session.".
-spec get_config(binary(), atom()) -> {ok, term()} | {error, not_set}.
get_config(SessionId, Key)
  when is_binary(SessionId), is_atom(Key) ->
    ensure_tables(),
    case ets:lookup(?CONFIG_TABLE, {SessionId, Key}) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, not_set}
    end.

-doc "Set a config value for a session.".
-spec set_config(binary(), atom(), term()) -> ok.
set_config(SessionId, Key, Value)
  when is_binary(SessionId), is_atom(Key) ->
    ensure_tables(),
    ets:insert(?CONFIG_TABLE, {{SessionId, Key}, Value}),
    ok.

-doc "Get all config for a session as a map.".
-spec get_all_config(binary()) -> {ok, map()}.
get_all_config(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Config = ets:foldl(fun
        ({{SId, Key}, Value}, Acc) when SId =:= SessionId ->
            Acc#{Key => Value};
        (_, Acc) ->
            Acc
    end, #{}, ?CONFIG_TABLE),
    {ok, Config}.

-doc "Clear all config for a session.".
-spec clear_config(binary()) -> ok.
clear_config(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    %% Delete all keys for this session
    ets:foldl(fun
        ({{SId, _} = Key, _}, ok) when SId =:= SessionId ->
            ets:delete(?CONFIG_TABLE, Key),
            ok;
        (_, ok) ->
            ok
    end, ok, ?CONFIG_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Permission Mode
%%--------------------------------------------------------------------

-doc "Set the permission mode for a session.".
-spec set_permission_mode(binary(), binary() | atom()) -> ok.
set_permission_mode(SessionId, Mode) when is_binary(SessionId) ->
    set_config(SessionId, permission_mode, Mode).

-doc "Get the permission mode for a session.".
-spec get_permission_mode(binary()) ->
    {ok, binary() | atom()} | {error, not_set}.
get_permission_mode(SessionId) when is_binary(SessionId) ->
    get_config(SessionId, permission_mode).

%%--------------------------------------------------------------------
%% Thinking Tokens
%%--------------------------------------------------------------------

-doc "Set max thinking tokens for a session.".
-spec set_max_thinking_tokens(binary(), pos_integer()) -> ok.
set_max_thinking_tokens(SessionId, Tokens)
  when is_binary(SessionId), is_integer(Tokens), Tokens > 0 ->
    set_config(SessionId, max_thinking_tokens, Tokens).

-doc "Get max thinking tokens for a session.".
-spec get_max_thinking_tokens(binary()) ->
    {ok, pos_integer()} | {error, not_set}.
get_max_thinking_tokens(SessionId) when is_binary(SessionId) ->
    get_config(SessionId, max_thinking_tokens).

%%--------------------------------------------------------------------
%% Task Tracking
%%--------------------------------------------------------------------

-doc "Register an active task for a session.".
-spec register_task(binary(), binary(), pid()) -> ok.
register_task(SessionId, TaskId, Pid)
  when is_binary(SessionId), is_binary(TaskId), is_pid(Pid) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Task = #{
        task_id => TaskId,
        session_id => SessionId,
        pid => Pid,
        started_at => Now,
        status => running
    },
    ets:insert(?TASKS_TABLE, {{SessionId, TaskId}, Task}),
    ok.

-doc "Unregister a task (mark as complete).".
-spec unregister_task(binary(), binary()) -> ok.
unregister_task(SessionId, TaskId)
  when is_binary(SessionId), is_binary(TaskId) ->
    ensure_tables(),
    ets:delete(?TASKS_TABLE, {SessionId, TaskId}),
    ok.

-doc """
Stop a running task by sending an interrupt to its process.
Returns `ok` if the task was found and signaled, error otherwise.
""".
-spec stop_task(binary(), binary()) -> ok | {error, not_found}.
stop_task(SessionId, TaskId)
  when is_binary(SessionId), is_binary(TaskId) ->
    ensure_tables(),
    Key = {SessionId, TaskId},
    case ets:lookup(?TASKS_TABLE, Key) of
        [{_, #{pid := Pid, status := running} = Task}] ->
            %% Signal the process to stop
            case is_process_alive(Pid) of
                true ->
                    %% Try gen_statem interrupt first, fall back to exit
                    try
                        gen_statem:call(Pid, interrupt, 5000)
                    catch
                        _:_ ->
                            exit(Pid, shutdown)
                    end;
                false ->
                    ok
            end,
            Updated = Task#{status => stopped},
            ets:insert(?TASKS_TABLE, {Key, Updated}),
            ok;
        [{_, #{status := stopped}}] ->
            ok;
        [] ->
            {error, not_found}
    end.

-doc "List all tasks for a session.".
-spec list_tasks(binary()) -> {ok, [task_meta()]}.
list_tasks(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Tasks = ets:foldl(fun
        ({{SId, _}, Task}, Acc) when SId =:= SessionId ->
            [Task | Acc];
        (_, Acc) ->
            Acc
    end, [], ?TASKS_TABLE),
    {ok, Tasks}.

%%--------------------------------------------------------------------
%% Feedback
%%--------------------------------------------------------------------

-doc "Submit feedback for a session. Feedback is accumulated.".
-spec submit_feedback(binary(), map()) -> ok.
submit_feedback(SessionId, Feedback)
  when is_binary(SessionId), is_map(Feedback) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Seq = ets:update_counter(?FEEDBACK_TABLE, {SessionId, seq},
        {2, 1}, {{SessionId, seq}, 0}),
    Entry = Feedback#{
        submitted_at => Now,
        session_id => SessionId,
        seq => Seq
    },
    ets:insert(?FEEDBACK_TABLE, {{SessionId, Seq}, Entry}),
    ok.

-doc "Get all feedback for a session, in submission order.".
-spec get_feedback(binary()) -> {ok, [map()]}.
get_feedback(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Feedback = ets:foldl(fun
        ({{SId, Key}, Entry}, Acc) when SId =:= SessionId, Key =/= seq ->
            [Entry | Acc];
        (_, Acc) ->
            Acc
    end, [], ?FEEDBACK_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(seq, A, 0) =< maps:get(seq, B, 0)
    end, Feedback),
    {ok, Sorted}.

-doc "Clear all feedback for a session.".
-spec clear_feedback(binary()) -> ok.
clear_feedback(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    ets:foldl(fun
        ({{SId, _} = Key, _}, ok) when SId =:= SessionId ->
            ets:delete(?FEEDBACK_TABLE, Key),
            ok;
        (_, ok) ->
            ok
    end, ok, ?FEEDBACK_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Turn Response (Pending Request/Response)
%%--------------------------------------------------------------------

-doc """
Store a pending request from the agent.
Called when the agent asks for user input.
""".
-spec store_pending_request(binary(), binary(), map()) -> ok.
store_pending_request(SessionId, RequestId, Request)
  when is_binary(SessionId), is_binary(RequestId), is_map(Request) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Entry = #{
        request_id => RequestId,
        session_id => SessionId,
        request => Request,
        status => pending,
        created_at => Now
    },
    ets:insert(?PENDING_TABLE, {{SessionId, RequestId}, Entry}),
    ok.

-doc "Resolve a pending request with a response.".
-spec resolve_pending_request(binary(), binary(), map()) ->
    ok | {error, not_found | already_resolved}.
resolve_pending_request(SessionId, RequestId, Response)
  when is_binary(SessionId), is_binary(RequestId), is_map(Response) ->
    ensure_tables(),
    Key = {SessionId, RequestId},
    case ets:lookup(?PENDING_TABLE, Key) of
        [{_, #{status := pending} = Entry}] ->
            Now = erlang:system_time(millisecond),
            Updated = Entry#{
                status => resolved,
                response => Response,
                resolved_at => Now
            },
            ets:insert(?PENDING_TABLE, {Key, Updated}),
            ok;
        [{_, #{status := resolved}}] ->
            {error, already_resolved};
        [] ->
            {error, not_found}
    end.

-doc "Get the response for a pending request.".
-spec get_pending_response(binary(), binary()) ->
    {ok, map()} | {error, pending | not_found}.
get_pending_response(SessionId, RequestId)
  when is_binary(SessionId), is_binary(RequestId) ->
    ensure_tables(),
    Key = {SessionId, RequestId},
    case ets:lookup(?PENDING_TABLE, Key) of
        [{_, #{status := resolved, response := Response}}] ->
            {ok, Response};
        [{_, #{status := pending}}] ->
            {error, pending};
        [] ->
            {error, not_found}
    end.

-doc "List all pending requests for a session.".
-spec list_pending_requests(binary()) -> {ok, [pending_request()]}.
list_pending_requests(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    Requests = ets:foldl(fun
        ({{SId, _}, Entry}, Acc) when SId =:= SessionId ->
            [Entry | Acc];
        (_, Acc) ->
            Acc
    end, [], ?PENDING_TABLE),
    {ok, Requests}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec ensure_ets(atom(), [term()]) -> ok.
ensure_ets(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.
