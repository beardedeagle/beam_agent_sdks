%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire_control (session control protocol).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Control dispatch (setModel, setPermissionMode, setMaxThinkingTokens,
%%%     stopTask, unknown method, missing params, invalid params)
%%%   - Session config CRUD (get_config, set_config, get_all_config, clear_config)
%%%   - Permission mode convenience (set_permission_mode, get_permission_mode)
%%%   - Thinking tokens convenience (set_max_thinking_tokens, get_max_thinking_tokens)
%%%   - Task tracking lifecycle (register_task, unregister_task, stop_task, list_tasks)
%%%   - Feedback accumulation (submit_feedback, get_feedback, clear_feedback)
%%%   - Pending request lifecycle (store_pending_request, resolve_pending_request,
%%%     get_pending_response, list_pending_requests)
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_control_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = agent_wire_control:ensure_tables(),
    ok = agent_wire_control:ensure_tables(),
    ok = agent_wire_control:ensure_tables(),
    agent_wire_control:clear().

clear_empties_all_tables_test() ->
    SId = <<"clear-session">>,
    agent_wire_control:ensure_tables(),
    agent_wire_control:set_config(SId, model, <<"claude">>),
    agent_wire_control:submit_feedback(SId, #{rating => good}),
    agent_wire_control:store_pending_request(SId, <<"r1">>, #{q => <<"hi">>}),
    ok = agent_wire_control:clear(),
    ?assertEqual({error, not_set}, agent_wire_control:get_config(SId, model)),
    {ok, Feedback} = agent_wire_control:get_feedback(SId),
    ?assertEqual([], Feedback),
    {ok, Pending} = agent_wire_control:list_pending_requests(SId),
    ?assertEqual([], Pending).

%%====================================================================
%% Dispatch: setModel
%%====================================================================

dispatch_set_model_test() ->
    SId = <<"disp-model-session">>,
    {ok, Result} = agent_wire_control:dispatch(SId, <<"setModel">>,
        #{<<"model">> => <<"claude-opus-4-6">>}),
    ?assertEqual(<<"claude-opus-4-6">>, maps:get(model, Result)),
    {ok, Stored} = agent_wire_control:get_config(SId, model),
    ?assertEqual(<<"claude-opus-4-6">>, Stored),
    agent_wire_control:clear().

dispatch_set_model_missing_param_test() ->
    SId = <<"disp-model-miss-session">>,
    ?assertMatch({error, {missing_param, model}},
        agent_wire_control:dispatch(SId, <<"setModel">>, #{})),
    agent_wire_control:clear().

%%====================================================================
%% Dispatch: setPermissionMode
%%====================================================================

dispatch_set_permission_mode_test() ->
    SId = <<"disp-perm-session">>,
    {ok, Result} = agent_wire_control:dispatch(SId, <<"setPermissionMode">>,
        #{<<"permissionMode">> => <<"acceptEdits">>}),
    ?assertEqual(<<"acceptEdits">>, maps:get(permission_mode, Result)),
    {ok, Stored} = agent_wire_control:get_permission_mode(SId),
    ?assertEqual(<<"acceptEdits">>, Stored),
    agent_wire_control:clear().

dispatch_set_permission_mode_missing_param_test() ->
    SId = <<"disp-perm-miss-session">>,
    ?assertMatch({error, {missing_param, permission_mode}},
        agent_wire_control:dispatch(SId, <<"setPermissionMode">>, #{})),
    agent_wire_control:clear().

%%====================================================================
%% Dispatch: setMaxThinkingTokens
%%====================================================================

dispatch_set_max_thinking_tokens_test() ->
    SId = <<"disp-tokens-session">>,
    {ok, Result} = agent_wire_control:dispatch(SId, <<"setMaxThinkingTokens">>,
        #{<<"maxThinkingTokens">> => 8192}),
    ?assertEqual(8192, maps:get(max_thinking_tokens, Result)),
    {ok, Stored} = agent_wire_control:get_max_thinking_tokens(SId),
    ?assertEqual(8192, Stored),
    agent_wire_control:clear().

dispatch_set_max_thinking_tokens_missing_param_test() ->
    SId = <<"disp-tokens-miss-session">>,
    ?assertMatch({error, {missing_param, max_thinking_tokens}},
        agent_wire_control:dispatch(SId, <<"setMaxThinkingTokens">>, #{})),
    agent_wire_control:clear().

dispatch_set_max_thinking_tokens_invalid_zero_test() ->
    SId = <<"disp-tokens-zero-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        agent_wire_control:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => 0})),
    agent_wire_control:clear().

dispatch_set_max_thinking_tokens_invalid_negative_test() ->
    SId = <<"disp-tokens-neg-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        agent_wire_control:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => -100})),
    agent_wire_control:clear().

dispatch_set_max_thinking_tokens_invalid_string_test() ->
    SId = <<"disp-tokens-str-session">>,
    ?assertMatch({error, {invalid_param, max_thinking_tokens}},
        agent_wire_control:dispatch(SId, <<"setMaxThinkingTokens">>,
            #{<<"maxThinkingTokens">> => <<"8192">>})),
    agent_wire_control:clear().

%%====================================================================
%% Dispatch: stopTask
%%====================================================================

dispatch_stop_task_test() ->
    SId = <<"disp-stop-session">>,
    TaskId = <<"task-001">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    agent_wire_control:register_task(SId, TaskId, Pid),
    ok = agent_wire_control:dispatch(SId, <<"stopTask">>,
        #{<<"taskId">> => TaskId}),
    agent_wire_control:clear().

dispatch_stop_task_missing_param_test() ->
    SId = <<"disp-stop-miss-session">>,
    ?assertMatch({error, {missing_param, task_id}},
        agent_wire_control:dispatch(SId, <<"stopTask">>, #{})),
    agent_wire_control:clear().

%%====================================================================
%% Dispatch: unknown method
%%====================================================================

dispatch_unknown_method_test() ->
    SId = <<"disp-unknown-session">>,
    ?assertMatch({error, {unknown_method, <<"doSomethingUnknown">>}},
        agent_wire_control:dispatch(SId, <<"doSomethingUnknown">>, #{})),
    agent_wire_control:clear().

%%====================================================================
%% Session config CRUD
%%====================================================================

get_config_not_set_test() ->
    SId = <<"cfg-notset-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_set}, agent_wire_control:get_config(SId, model)),
    agent_wire_control:clear().

set_and_get_config_test() ->
    SId = <<"cfg-set-session">>,
    ok = agent_wire_control:set_config(SId, model, <<"claude-haiku">>),
    ?assertEqual({ok, <<"claude-haiku">>}, agent_wire_control:get_config(SId, model)),
    agent_wire_control:clear().

set_config_overwrite_test() ->
    SId = <<"cfg-overwrite-session">>,
    ok = agent_wire_control:set_config(SId, model, <<"model-v1">>),
    ok = agent_wire_control:set_config(SId, model, <<"model-v2">>),
    ?assertEqual({ok, <<"model-v2">>}, agent_wire_control:get_config(SId, model)),
    agent_wire_control:clear().

get_all_config_empty_test() ->
    SId = <<"cfg-all-empty-session">>,
    agent_wire_control:ensure_tables(),
    {ok, Config} = agent_wire_control:get_all_config(SId),
    ?assertEqual(#{}, Config),
    agent_wire_control:clear().

get_all_config_multiple_keys_test() ->
    SId = <<"cfg-all-multi-session">>,
    agent_wire_control:set_config(SId, model, <<"claude-sonnet">>),
    agent_wire_control:set_config(SId, permission_mode, <<"acceptEdits">>),
    {ok, Config} = agent_wire_control:get_all_config(SId),
    ?assertEqual(<<"claude-sonnet">>, maps:get(model, Config)),
    ?assertEqual(<<"acceptEdits">>, maps:get(permission_mode, Config)),
    agent_wire_control:clear().

get_all_config_isolates_sessions_test() ->
    SId1 = <<"cfg-iso-session-1">>,
    SId2 = <<"cfg-iso-session-2">>,
    agent_wire_control:set_config(SId1, model, <<"model-1">>),
    agent_wire_control:set_config(SId2, model, <<"model-2">>),
    {ok, Config1} = agent_wire_control:get_all_config(SId1),
    {ok, Config2} = agent_wire_control:get_all_config(SId2),
    ?assertEqual(<<"model-1">>, maps:get(model, Config1)),
    ?assertEqual(<<"model-2">>, maps:get(model, Config2)),
    ?assertNot(maps:is_key(model, maps:without([model], Config1))
        andalso maps:get(model, Config1) =:= <<"model-2">>),
    agent_wire_control:clear().

clear_config_test() ->
    SId = <<"cfg-clear-session">>,
    agent_wire_control:set_config(SId, model, <<"claude">>),
    agent_wire_control:set_config(SId, permission_mode, <<"default">>),
    ok = agent_wire_control:clear_config(SId),
    ?assertEqual({error, not_set}, agent_wire_control:get_config(SId, model)),
    ?assertEqual({error, not_set}, agent_wire_control:get_config(SId, permission_mode)),
    agent_wire_control:clear().

clear_config_does_not_affect_other_sessions_test() ->
    SId1 = <<"cfg-clr-iso-1">>,
    SId2 = <<"cfg-clr-iso-2">>,
    agent_wire_control:set_config(SId1, model, <<"claude">>),
    agent_wire_control:set_config(SId2, model, <<"other">>),
    agent_wire_control:clear_config(SId1),
    ?assertEqual({error, not_set}, agent_wire_control:get_config(SId1, model)),
    ?assertEqual({ok, <<"other">>}, agent_wire_control:get_config(SId2, model)),
    agent_wire_control:clear().

%%====================================================================
%% Permission mode convenience
%%====================================================================

set_get_permission_mode_test() ->
    SId = <<"perm-session">>,
    ok = agent_wire_control:set_permission_mode(SId, <<"bypassPermissions">>),
    ?assertEqual({ok, <<"bypassPermissions">>},
        agent_wire_control:get_permission_mode(SId)),
    agent_wire_control:clear().

get_permission_mode_not_set_test() ->
    SId = <<"perm-notset-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_set}, agent_wire_control:get_permission_mode(SId)),
    agent_wire_control:clear().

%%====================================================================
%% Thinking tokens convenience
%%====================================================================

set_get_max_thinking_tokens_test() ->
    SId = <<"tokens-session">>,
    ok = agent_wire_control:set_max_thinking_tokens(SId, 16384),
    ?assertEqual({ok, 16384}, agent_wire_control:get_max_thinking_tokens(SId)),
    agent_wire_control:clear().

get_max_thinking_tokens_not_set_test() ->
    SId = <<"tokens-notset-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_set}, agent_wire_control:get_max_thinking_tokens(SId)),
    agent_wire_control:clear().

%%====================================================================
%% Task tracking
%%====================================================================

register_and_list_tasks_test() ->
    SId = <<"task-list-session">>,
    Pid = spawn(fun() -> timer:sleep(60000) end),
    ok = agent_wire_control:register_task(SId, <<"task-1">>, Pid),
    {ok, Tasks} = agent_wire_control:list_tasks(SId),
    ?assertEqual(1, length(Tasks)),
    [Task] = Tasks,
    ?assertEqual(<<"task-1">>, maps:get(task_id, Task)),
    ?assertEqual(SId, maps:get(session_id, Task)),
    ?assertEqual(Pid, maps:get(pid, Task)),
    ?assertEqual(running, maps:get(status, Task)),
    exit(Pid, kill),
    agent_wire_control:clear().

list_tasks_empty_test() ->
    SId = <<"task-empty-session">>,
    agent_wire_control:ensure_tables(),
    {ok, Tasks} = agent_wire_control:list_tasks(SId),
    ?assertEqual([], Tasks),
    agent_wire_control:clear().

unregister_task_test() ->
    SId = <<"task-unreg-session">>,
    Pid = spawn(fun() -> timer:sleep(60000) end),
    agent_wire_control:register_task(SId, <<"task-x">>, Pid),
    ok = agent_wire_control:unregister_task(SId, <<"task-x">>),
    {ok, Tasks} = agent_wire_control:list_tasks(SId),
    ?assertEqual([], Tasks),
    exit(Pid, kill),
    agent_wire_control:clear().

stop_task_running_test() ->
    SId = <<"task-stop-session">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    agent_wire_control:register_task(SId, <<"task-stop">>, Pid),
    ok = agent_wire_control:stop_task(SId, <<"task-stop">>),
    %% Task should be marked stopped, still in list
    {ok, Tasks} = agent_wire_control:list_tasks(SId),
    ?assertEqual(1, length(Tasks)),
    [Task] = Tasks,
    ?assertEqual(stopped, maps:get(status, Task)),
    agent_wire_control:clear().

stop_task_already_stopped_test() ->
    SId = <<"task-already-stopped-session">>,
    Pid = spawn(fun() -> ok end),
    timer:sleep(10),
    agent_wire_control:register_task(SId, <<"task-s2">>, Pid),
    ok = agent_wire_control:stop_task(SId, <<"task-s2">>),
    %% Second stop on an already-stopped task returns ok
    ok = agent_wire_control:stop_task(SId, <<"task-s2">>),
    agent_wire_control:clear().

stop_task_not_found_test() ->
    SId = <<"task-notfound-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_found},
        agent_wire_control:stop_task(SId, <<"no-such-task">>)),
    agent_wire_control:clear().

stop_task_dead_process_test() ->
    SId = <<"task-dead-session">>,
    Pid = spawn(fun() -> ok end),
    %% Let process finish
    timer:sleep(10),
    agent_wire_control:register_task(SId, <<"task-dead">>, Pid),
    %% Should handle dead process gracefully
    ok = agent_wire_control:stop_task(SId, <<"task-dead">>),
    agent_wire_control:clear().

list_tasks_isolates_sessions_test() ->
    SId1 = <<"task-iso-1">>,
    SId2 = <<"task-iso-2">>,
    Pid1 = spawn(fun() -> ok end),
    Pid2 = spawn(fun() -> ok end),
    agent_wire_control:register_task(SId1, <<"t1">>, Pid1),
    agent_wire_control:register_task(SId2, <<"t2">>, Pid2),
    {ok, Tasks1} = agent_wire_control:list_tasks(SId1),
    {ok, Tasks2} = agent_wire_control:list_tasks(SId2),
    ?assertEqual(1, length(Tasks1)),
    ?assertEqual(1, length(Tasks2)),
    [T1] = Tasks1,
    [T2] = Tasks2,
    ?assertEqual(<<"t1">>, maps:get(task_id, T1)),
    ?assertEqual(<<"t2">>, maps:get(task_id, T2)),
    agent_wire_control:clear().

%%====================================================================
%% Feedback
%%====================================================================

submit_and_get_feedback_test() ->
    SId = <<"fb-basic-session">>,
    ok = agent_wire_control:submit_feedback(SId, #{rating => good}),
    {ok, Feedback} = agent_wire_control:get_feedback(SId),
    ?assertEqual(1, length(Feedback)),
    [Entry] = Feedback,
    ?assertEqual(good, maps:get(rating, Entry)),
    ?assertEqual(SId, maps:get(session_id, Entry)),
    agent_wire_control:clear().

feedback_ordering_test() ->
    SId = <<"fb-order-session">>,
    agent_wire_control:submit_feedback(SId, #{order => first}),
    agent_wire_control:submit_feedback(SId, #{order => second}),
    agent_wire_control:submit_feedback(SId, #{order => third}),
    {ok, Feedback} = agent_wire_control:get_feedback(SId),
    ?assertEqual(3, length(Feedback)),
    [F1, F2, F3] = Feedback,
    ?assertEqual(first, maps:get(order, F1)),
    ?assertEqual(second, maps:get(order, F2)),
    ?assertEqual(third, maps:get(order, F3)),
    agent_wire_control:clear().

get_feedback_empty_test() ->
    SId = <<"fb-empty-session">>,
    agent_wire_control:ensure_tables(),
    {ok, Feedback} = agent_wire_control:get_feedback(SId),
    ?assertEqual([], Feedback),
    agent_wire_control:clear().

clear_feedback_test() ->
    SId = <<"fb-clear-session">>,
    agent_wire_control:submit_feedback(SId, #{rating => bad}),
    agent_wire_control:submit_feedback(SId, #{rating => good}),
    ok = agent_wire_control:clear_feedback(SId),
    {ok, Feedback} = agent_wire_control:get_feedback(SId),
    ?assertEqual([], Feedback),
    agent_wire_control:clear().

clear_feedback_does_not_affect_other_sessions_test() ->
    SId1 = <<"fb-clr-iso-1">>,
    SId2 = <<"fb-clr-iso-2">>,
    agent_wire_control:submit_feedback(SId1, #{from => s1}),
    agent_wire_control:submit_feedback(SId2, #{from => s2}),
    agent_wire_control:clear_feedback(SId1),
    {ok, F1} = agent_wire_control:get_feedback(SId1),
    {ok, F2} = agent_wire_control:get_feedback(SId2),
    ?assertEqual([], F1),
    ?assertEqual(1, length(F2)),
    agent_wire_control:clear().

%%====================================================================
%% Pending request lifecycle
%%====================================================================

store_and_list_pending_requests_test() ->
    SId = <<"pr-list-session">>,
    Request = #{<<"type">> => <<"user_input">>, <<"prompt">> => <<"Enter value:">>},
    ok = agent_wire_control:store_pending_request(SId, <<"req-1">>, Request),
    {ok, Reqs} = agent_wire_control:list_pending_requests(SId),
    ?assertEqual(1, length(Reqs)),
    [Req] = Reqs,
    ?assertEqual(<<"req-1">>, maps:get(request_id, Req)),
    ?assertEqual(pending, maps:get(status, Req)),
    agent_wire_control:clear().

list_pending_requests_empty_test() ->
    SId = <<"pr-empty-session">>,
    agent_wire_control:ensure_tables(),
    {ok, Reqs} = agent_wire_control:list_pending_requests(SId),
    ?assertEqual([], Reqs),
    agent_wire_control:clear().

get_pending_response_unresolved_test() ->
    SId = <<"pr-unres-session">>,
    agent_wire_control:store_pending_request(SId, <<"req-u">>,
        #{<<"prompt">> => <<"??">>}),
    ?assertEqual({error, pending},
        agent_wire_control:get_pending_response(SId, <<"req-u">>)),
    agent_wire_control:clear().

get_pending_response_not_found_test() ->
    SId = <<"pr-notfound-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_found},
        agent_wire_control:get_pending_response(SId, <<"no-such-req">>)),
    agent_wire_control:clear().

resolve_pending_request_test() ->
    SId = <<"pr-resolve-session">>,
    agent_wire_control:store_pending_request(SId, <<"req-r">>,
        #{<<"prompt">> => <<"Enter:">>}),
    Response = #{<<"value">> => <<"user-answer">>},
    ok = agent_wire_control:resolve_pending_request(SId, <<"req-r">>, Response),
    {ok, Got} = agent_wire_control:get_pending_response(SId, <<"req-r">>),
    ?assertEqual(<<"user-answer">>, maps:get(<<"value">>, Got)),
    agent_wire_control:clear().

resolve_pending_request_double_resolve_test() ->
    SId = <<"pr-double-session">>,
    agent_wire_control:store_pending_request(SId, <<"req-d">>,
        #{<<"prompt">> => <<"?">>}),
    ok = agent_wire_control:resolve_pending_request(SId, <<"req-d">>,
        #{<<"value">> => <<"first">>}),
    ?assertEqual({error, already_resolved},
        agent_wire_control:resolve_pending_request(SId, <<"req-d">>,
            #{<<"value">> => <<"second">>})),
    agent_wire_control:clear().

resolve_pending_request_not_found_test() ->
    SId = <<"pr-res-notfound-session">>,
    agent_wire_control:ensure_tables(),
    ?assertEqual({error, not_found},
        agent_wire_control:resolve_pending_request(SId, <<"no-such-req">>,
            #{<<"value">> => <<"x">>})),
    agent_wire_control:clear().

pending_requests_isolate_sessions_test() ->
    SId1 = <<"pr-iso-1">>,
    SId2 = <<"pr-iso-2">>,
    agent_wire_control:store_pending_request(SId1, <<"req-a">>, #{<<"q">> => <<"1">>}),
    agent_wire_control:store_pending_request(SId2, <<"req-b">>, #{<<"q">> => <<"2">>}),
    {ok, Reqs1} = agent_wire_control:list_pending_requests(SId1),
    {ok, Reqs2} = agent_wire_control:list_pending_requests(SId2),
    ?assertEqual(1, length(Reqs1)),
    ?assertEqual(1, length(Reqs2)),
    [R1] = Reqs1,
    [R2] = Reqs2,
    ?assertEqual(<<"req-a">>, maps:get(request_id, R1)),
    ?assertEqual(<<"req-b">>, maps:get(request_id, R2)),
    agent_wire_control:clear().
