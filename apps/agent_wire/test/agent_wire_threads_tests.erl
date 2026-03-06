%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire_threads (universal thread management).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_table, clear)
%%%   - Thread creation (start_thread) with auto-generated and explicit IDs
%%%   - Thread resumption (resume_thread) including not_found
%%%   - Thread listing (list_threads) sorted by updated_at descending
%%%   - Thread retrieval (get_thread) found and not_found
%%%   - Thread deletion (delete_thread) including active thread clear
%%%   - Message recording (record_thread_message) with count and updated_at
%%%   - Thread message retrieval (get_thread_messages) found and not_found
%%%   - Thread count (thread_count)
%%%   - Active thread management (active_thread, set_active_thread,
%%%     clear_active_thread)
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_threads_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_table_idempotent_test() ->
    ok = agent_wire_threads:ensure_table(),
    ok = agent_wire_threads:ensure_table(),
    ok = agent_wire_threads:ensure_table(),
    agent_wire_threads:clear().

clear_removes_all_data_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-clear">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId, #{}),
    {ok, [_]} = agent_wire_threads:list_threads(SessionId),
    ok = agent_wire_threads:clear(),
    {ok, []} = agent_wire_threads:list_threads(SessionId),
    agent_wire_threads:clear().

%%====================================================================
%% start_thread tests
%%====================================================================

start_thread_returns_thread_meta_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-start-1">>,
    {ok, Thread} = agent_wire_threads:start_thread(SessionId, #{}),
    ?assertEqual(SessionId, maps:get(session_id, Thread)),
    ?assert(is_binary(maps:get(thread_id, Thread))),
    ?assertEqual(0, maps:get(message_count, Thread)),
    ?assertEqual(active, maps:get(status, Thread)),
    ?assert(is_integer(maps:get(created_at, Thread))),
    ?assert(is_integer(maps:get(updated_at, Thread))),
    agent_wire_threads:clear().

start_thread_with_name_option_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-start-2">>,
    {ok, Thread} = agent_wire_threads:start_thread(SessionId,
        #{name => <<"my-thread">>}),
    ?assertEqual(<<"my-thread">>, maps:get(name, Thread)),
    agent_wire_threads:clear().

start_thread_with_explicit_thread_id_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-start-3">>,
    ExplicitId = <<"explicit-thread-id">>,
    {ok, Thread} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ExplicitId}),
    ?assertEqual(ExplicitId, maps:get(thread_id, Thread)),
    agent_wire_threads:clear().

start_thread_auto_generated_id_has_prefix_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-start-4">>,
    {ok, Thread} = agent_wire_threads:start_thread(SessionId, #{}),
    ThreadId = maps:get(thread_id, Thread),
    ?assert(binary:match(ThreadId, <<"thread_">>) =/= nomatch),
    agent_wire_threads:clear().

start_thread_sets_active_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-start-5">>,
    {ok, Thread} = agent_wire_threads:start_thread(SessionId, #{}),
    ThreadId = maps:get(thread_id, Thread),
    ?assertEqual({ok, ThreadId}, agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

%%====================================================================
%% resume_thread tests
%%====================================================================

resume_thread_sets_active_and_status_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-resume-1">>,
    {ok, T1} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-resume-a">>}),
    {ok, _T2} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-resume-b">>}),
    %% t-resume-b is now active; resume t-resume-a
    {ok, Resumed} = agent_wire_threads:resume_thread(SessionId,
        maps:get(thread_id, T1)),
    ?assertEqual(active, maps:get(status, Resumed)),
    ?assertEqual({ok, <<"t-resume-a">>},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

resume_thread_not_found_test() ->
    agent_wire_threads:ensure_table(),
    Result = agent_wire_threads:resume_thread(<<"sess-resume-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    agent_wire_threads:clear().

resume_thread_updates_updated_at_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-resume-3">>,
    ThreadId = <<"t-resume-time">>,
    {ok, Original} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    timer:sleep(5),
    {ok, Resumed} = agent_wire_threads:resume_thread(SessionId, ThreadId),
    ?assert(maps:get(updated_at, Resumed) >= maps:get(updated_at, Original)),
    agent_wire_threads:clear().

%%====================================================================
%% list_threads tests
%%====================================================================

list_threads_empty_test() ->
    agent_wire_threads:ensure_table(),
    {ok, List} = agent_wire_threads:list_threads(<<"sess-list-empty">>),
    ?assertEqual([], List),
    agent_wire_threads:clear().

list_threads_returns_only_own_session_test() ->
    agent_wire_threads:ensure_table(),
    {ok, _} = agent_wire_threads:start_thread(<<"sess-list-A">>,
        #{thread_id => <<"t-A1">>}),
    {ok, _} = agent_wire_threads:start_thread(<<"sess-list-B">>,
        #{thread_id => <<"t-B1">>}),
    {ok, ListA} = agent_wire_threads:list_threads(<<"sess-list-A">>),
    {ok, ListB} = agent_wire_threads:list_threads(<<"sess-list-B">>),
    ?assertEqual(1, length(ListA)),
    ?assertEqual(1, length(ListB)),
    ?assertEqual(<<"t-A1">>, maps:get(thread_id, hd(ListA))),
    ?assertEqual(<<"t-B1">>, maps:get(thread_id, hd(ListB))),
    agent_wire_threads:clear().

list_threads_sorted_newest_first_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-list-order">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-order-1">>}),
    timer:sleep(5),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-order-2">>}),
    timer:sleep(5),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-order-3">>}),
    {ok, List} = agent_wire_threads:list_threads(SessionId),
    ?assertEqual(3, length(List)),
    [First, Second, Third] = List,
    ?assert(maps:get(updated_at, First) >= maps:get(updated_at, Second)),
    ?assert(maps:get(updated_at, Second) >= maps:get(updated_at, Third)),
    agent_wire_threads:clear().

%%====================================================================
%% get_thread tests
%%====================================================================

get_thread_found_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-get-1">>,
    ThreadId = <<"t-get-1">>,
    {ok, Created} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    {ok, Got} = agent_wire_threads:get_thread(SessionId, ThreadId),
    ?assertEqual(Created, Got),
    agent_wire_threads:clear().

get_thread_not_found_test() ->
    agent_wire_threads:ensure_table(),
    Result = agent_wire_threads:get_thread(<<"sess-get-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    agent_wire_threads:clear().

%%====================================================================
%% delete_thread tests
%%====================================================================

delete_thread_removes_thread_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-del-1">>,
    ThreadId = <<"t-del-1">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    {ok, _} = agent_wire_threads:get_thread(SessionId, ThreadId),
    ok = agent_wire_threads:delete_thread(SessionId, ThreadId),
    ?assertEqual({error, not_found},
        agent_wire_threads:get_thread(SessionId, ThreadId)),
    agent_wire_threads:clear().

delete_thread_clears_active_if_it_was_active_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-del-2">>,
    ThreadId = <<"t-del-active">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    ?assertEqual({ok, ThreadId},
        agent_wire_threads:active_thread(SessionId)),
    ok = agent_wire_threads:delete_thread(SessionId, ThreadId),
    ?assertEqual({error, none},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

delete_thread_does_not_clear_active_for_other_thread_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-del-3">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-del-other-1">>}),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-del-other-2">>}),
    %% t-del-other-2 is now active
    ok = agent_wire_threads:delete_thread(SessionId, <<"t-del-other-1">>),
    ?assertEqual({ok, <<"t-del-other-2">>},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

%%====================================================================
%% record_thread_message tests
%%====================================================================

record_thread_message_increments_count_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    SessionId = <<"sess-msg-1">>,
    ThreadId = <<"t-msg-1">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    Msg = #{type => result, content => <<"hello">>},
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Thread} = agent_wire_threads:get_thread(SessionId, ThreadId),
    ?assertEqual(1, maps:get(message_count, Thread)),
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Thread2} = agent_wire_threads:get_thread(SessionId, ThreadId),
    ?assertEqual(2, maps:get(message_count, Thread2)),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

record_thread_message_updates_updated_at_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    SessionId = <<"sess-msg-2">>,
    ThreadId = <<"t-msg-2">>,
    {ok, Before} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    timer:sleep(5),
    Msg = #{type => result, content => <<"update">>},
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadId, Msg),
    {ok, After} = agent_wire_threads:get_thread(SessionId, ThreadId),
    ?assert(maps:get(updated_at, After) >= maps:get(updated_at, Before)),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

record_thread_message_nonexistent_thread_is_noop_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    SessionId = <<"sess-msg-3">>,
    Msg = #{type => result, content => <<"noop">>},
    %% Should not crash for a non-existent thread
    ok = agent_wire_threads:record_thread_message(SessionId,
        <<"no-such-thread">>, Msg),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

%%====================================================================
%% get_thread_messages tests
%%====================================================================

get_thread_messages_found_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    SessionId = <<"sess-getmsg-1">>,
    ThreadId = <<"t-getmsg-1">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadId}),
    Msg = #{type => result, content => <<"msg content">>},
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadId, Msg),
    {ok, Messages} = agent_wire_threads:get_thread_messages(SessionId, ThreadId),
    ?assertEqual(1, length(Messages)),
    [Received] = Messages,
    ?assertEqual(ThreadId, maps:get(thread_id, Received)),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

get_thread_messages_not_found_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    Result = agent_wire_threads:get_thread_messages(<<"sess-getmsg-2">>,
        <<"no-such-thread">>),
    ?assertEqual({error, not_found}, Result),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

get_thread_messages_filters_by_thread_test() ->
    agent_wire_threads:ensure_table(),
    agent_wire_session_store:ensure_tables(),
    SessionId = <<"sess-getmsg-3">>,
    ThreadIdA = <<"t-getmsg-A">>,
    ThreadIdB = <<"t-getmsg-B">>,
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadIdA}),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => ThreadIdB}),
    MsgA = #{type => result, content => <<"for A">>},
    MsgB = #{type => result, content => <<"for B">>},
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadIdA, MsgA),
    ok = agent_wire_threads:record_thread_message(SessionId, ThreadIdB, MsgB),
    {ok, MessagesA} = agent_wire_threads:get_thread_messages(SessionId, ThreadIdA),
    {ok, MessagesB} = agent_wire_threads:get_thread_messages(SessionId, ThreadIdB),
    ?assertEqual(1, length(MessagesA)),
    ?assertEqual(1, length(MessagesB)),
    [ReceivedA] = MessagesA,
    [ReceivedB] = MessagesB,
    ?assertEqual(ThreadIdA, maps:get(thread_id, ReceivedA)),
    ?assertEqual(ThreadIdB, maps:get(thread_id, ReceivedB)),
    agent_wire_threads:clear(),
    agent_wire_session_store:clear().

%%====================================================================
%% thread_count tests
%%====================================================================

thread_count_empty_test() ->
    agent_wire_threads:ensure_table(),
    ?assertEqual(0, agent_wire_threads:thread_count(<<"sess-count-empty">>)),
    agent_wire_threads:clear().

thread_count_increments_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-count-1">>,
    ?assertEqual(0, agent_wire_threads:thread_count(SessionId)),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-count-1">>}),
    ?assertEqual(1, agent_wire_threads:thread_count(SessionId)),
    {ok, _} = agent_wire_threads:start_thread(SessionId,
        #{thread_id => <<"t-count-2">>}),
    ?assertEqual(2, agent_wire_threads:thread_count(SessionId)),
    agent_wire_threads:clear().

thread_count_isolated_per_session_test() ->
    agent_wire_threads:ensure_table(),
    {ok, _} = agent_wire_threads:start_thread(<<"sess-count-A">>,
        #{thread_id => <<"t-iso-1">>}),
    {ok, _} = agent_wire_threads:start_thread(<<"sess-count-A">>,
        #{thread_id => <<"t-iso-2">>}),
    {ok, _} = agent_wire_threads:start_thread(<<"sess-count-B">>,
        #{thread_id => <<"t-iso-3">>}),
    ?assertEqual(2, agent_wire_threads:thread_count(<<"sess-count-A">>)),
    ?assertEqual(1, agent_wire_threads:thread_count(<<"sess-count-B">>)),
    agent_wire_threads:clear().

%%====================================================================
%% active_thread / set_active_thread / clear_active_thread tests
%%====================================================================

active_thread_none_initially_test() ->
    agent_wire_threads:ensure_table(),
    ?assertEqual({error, none},
        agent_wire_threads:active_thread(<<"sess-active-none">>)),
    agent_wire_threads:clear().

set_active_thread_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-active-1">>,
    ThreadId = <<"t-active-1">>,
    ok = agent_wire_threads:set_active_thread(SessionId, ThreadId),
    ?assertEqual({ok, ThreadId},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

set_active_thread_overrides_previous_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-active-2">>,
    ok = agent_wire_threads:set_active_thread(SessionId, <<"t-first">>),
    ok = agent_wire_threads:set_active_thread(SessionId, <<"t-second">>),
    ?assertEqual({ok, <<"t-second">>},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

clear_active_thread_test() ->
    agent_wire_threads:ensure_table(),
    SessionId = <<"sess-active-3">>,
    ok = agent_wire_threads:set_active_thread(SessionId, <<"t-active-3">>),
    ?assertMatch({ok, _}, agent_wire_threads:active_thread(SessionId)),
    ok = agent_wire_threads:clear_active_thread(SessionId),
    ?assertEqual({error, none},
        agent_wire_threads:active_thread(SessionId)),
    agent_wire_threads:clear().

clear_active_thread_noop_when_none_test() ->
    agent_wire_threads:ensure_table(),
    ok = agent_wire_threads:clear_active_thread(<<"sess-active-noop">>),
    ?assertEqual({error, none},
        agent_wire_threads:active_thread(<<"sess-active-noop">>)),
    agent_wire_threads:clear().

active_thread_isolated_per_session_test() ->
    agent_wire_threads:ensure_table(),
    ok = agent_wire_threads:set_active_thread(<<"sess-iso-A">>, <<"t-iso-A">>),
    ok = agent_wire_threads:set_active_thread(<<"sess-iso-B">>, <<"t-iso-B">>),
    ?assertEqual({ok, <<"t-iso-A">>},
        agent_wire_threads:active_thread(<<"sess-iso-A">>)),
    ?assertEqual({ok, <<"t-iso-B">>},
        agent_wire_threads:active_thread(<<"sess-iso-B">>)),
    agent_wire_threads:clear().
