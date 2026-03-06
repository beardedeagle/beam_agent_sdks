%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire_session_store (session history store).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_tables, clear)
%%%   - Session metadata (register_session, update_session, get_session,
%%%     delete_session, list_sessions/0, list_sessions/1 with filters)
%%%   - Message storage (record_message, record_messages,
%%%     get_session_messages/1, get_session_messages/2 with opts)
%%%   - Convenience (session_count, message_count)
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_session_store_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_tables_idempotent_test() ->
    ok = agent_wire_session_store:ensure_tables(),
    ok = agent_wire_session_store:ensure_tables(),
    ok = agent_wire_session_store:ensure_tables(),
    agent_wire_session_store:clear().

clear_empties_all_tables_test() ->
    SId = <<"clear-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"hi">>}),
    ok = agent_wire_session_store:clear(),
    ?assertEqual({error, not_found}, agent_wire_session_store:get_session(SId)),
    ?assertEqual(0, agent_wire_session_store:session_count()),
    ?assertEqual(0, agent_wire_session_store:message_count(SId)).

%%====================================================================
%% register_session
%%====================================================================

register_session_test() ->
    SId = <<"reg-basic-session">>,
    ok = agent_wire_session_store:register_session(SId,
        #{adapter => claude, model => <<"claude-sonnet-4-6">>}),
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(SId, maps:get(session_id, Meta)),
    ?assertEqual(claude, maps:get(adapter, Meta)),
    ?assertEqual(<<"claude-sonnet-4-6">>, maps:get(model, Meta)),
    ?assert(is_integer(maps:get(created_at, Meta))),
    ?assert(is_integer(maps:get(updated_at, Meta))),
    agent_wire_session_store:clear().

register_session_idempotent_test() ->
    SId = <<"reg-idem-session">>,
    ok = agent_wire_session_store:register_session(SId, #{model => <<"v1">>}),
    ok = agent_wire_session_store:register_session(SId, #{model => <<"v2">>}),
    %% Second call is a no-op; original data preserved
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(<<"v1">>, maps:get(model, Meta)),
    agent_wire_session_store:clear().

%%====================================================================
%% update_session
%%====================================================================

update_session_merges_fields_test() ->
    SId = <<"upd-merge-session">>,
    agent_wire_session_store:register_session(SId,
        #{adapter => gemini, model => <<"gemini-1.5">>}),
    ok = agent_wire_session_store:update_session(SId, #{model => <<"gemini-2.0">>}),
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(gemini, maps:get(adapter, Meta)),
    ?assertEqual(<<"gemini-2.0">>, maps:get(model, Meta)),
    agent_wire_session_store:clear().

update_session_auto_creates_test() ->
    SId = <<"upd-autocreate-session">>,
    agent_wire_session_store:ensure_tables(),
    %% Session does not exist yet
    ?assertEqual({error, not_found}, agent_wire_session_store:get_session(SId)),
    ok = agent_wire_session_store:update_session(SId, #{adapter => codex}),
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(SId, maps:get(session_id, Meta)),
    agent_wire_session_store:clear().

%%====================================================================
%% get_session
%%====================================================================

get_session_not_found_test() ->
    agent_wire_session_store:ensure_tables(),
    ?assertEqual({error, not_found},
        agent_wire_session_store:get_session(<<"no-such-session">>)),
    agent_wire_session_store:clear().

%%====================================================================
%% delete_session
%%====================================================================

delete_session_removes_metadata_test() ->
    SId = <<"del-meta-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    ok = agent_wire_session_store:delete_session(SId),
    ?assertEqual({error, not_found}, agent_wire_session_store:get_session(SId)),
    agent_wire_session_store:clear().

delete_session_removes_messages_test() ->
    SId = <<"del-msgs-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"a">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"b">>}),
    ok = agent_wire_session_store:delete_session(SId),
    %% Session gone, message_count falls back to counter (which is also deleted)
    ?assertEqual(0, agent_wire_session_store:message_count(SId)),
    agent_wire_session_store:clear().

delete_session_nonexistent_test() ->
    agent_wire_session_store:ensure_tables(),
    %% Deleting a non-existent session is a no-op
    ok = agent_wire_session_store:delete_session(<<"ghost-session">>),
    agent_wire_session_store:clear().

%%====================================================================
%% list_sessions/0 and list_sessions/1
%%====================================================================

list_sessions_empty_test() ->
    agent_wire_session_store:ensure_tables(),
    {ok, Sessions} = agent_wire_session_store:list_sessions(),
    ?assertEqual([], Sessions),
    agent_wire_session_store:clear().

list_sessions_all_test() ->
    agent_wire_session_store:register_session(<<"ls-a">>, #{adapter => claude}),
    agent_wire_session_store:register_session(<<"ls-b">>, #{adapter => gemini}),
    {ok, Sessions} = agent_wire_session_store:list_sessions(),
    Ids = lists:sort([maps:get(session_id, S) || S <- Sessions]),
    ?assertEqual([<<"ls-a">>, <<"ls-b">>], Ids),
    agent_wire_session_store:clear().

list_sessions_filter_adapter_test() ->
    agent_wire_session_store:register_session(<<"fa-c">>, #{adapter => claude}),
    agent_wire_session_store:register_session(<<"fa-g">>, #{adapter => gemini}),
    agent_wire_session_store:register_session(<<"fa-g2">>, #{adapter => gemini}),
    {ok, Sessions} = agent_wire_session_store:list_sessions(#{adapter => gemini}),
    Ids = lists:sort([maps:get(session_id, S) || S <- Sessions]),
    ?assertEqual([<<"fa-g">>, <<"fa-g2">>], Ids),
    agent_wire_session_store:clear().

list_sessions_filter_model_test() ->
    agent_wire_session_store:register_session(<<"fm-s">>,
        #{model => <<"claude-sonnet-4-6">>}),
    agent_wire_session_store:register_session(<<"fm-h">>,
        #{model => <<"claude-haiku">>}),
    {ok, Sessions} = agent_wire_session_store:list_sessions(
        #{model => <<"claude-sonnet-4-6">>}),
    ?assertEqual(1, length(Sessions)),
    [S] = Sessions,
    ?assertEqual(<<"fm-s">>, maps:get(session_id, S)),
    agent_wire_session_store:clear().

list_sessions_filter_limit_test() ->
    agent_wire_session_store:register_session(<<"lim-1">>, #{adapter => claude}),
    timer:sleep(1),
    agent_wire_session_store:register_session(<<"lim-2">>, #{adapter => claude}),
    timer:sleep(1),
    agent_wire_session_store:register_session(<<"lim-3">>, #{adapter => claude}),
    {ok, Sessions} = agent_wire_session_store:list_sessions(#{limit => 2}),
    ?assertEqual(2, length(Sessions)),
    agent_wire_session_store:clear().

list_sessions_filter_since_test() ->
    Before = erlang:system_time(millisecond),
    timer:sleep(5),
    agent_wire_session_store:register_session(<<"since-new">>, #{adapter => claude}),
    {ok, Sessions} = agent_wire_session_store:list_sessions(#{since => Before}),
    Ids = [maps:get(session_id, S) || S <- Sessions],
    ?assert(lists:member(<<"since-new">>, Ids)),
    agent_wire_session_store:clear().

%%====================================================================
%% record_message and record_messages
%%====================================================================

record_message_auto_creates_session_test() ->
    SId = <<"msg-autocreate-session">>,
    agent_wire_session_store:ensure_tables(),
    ok = agent_wire_session_store:record_message(SId,
        #{type => text, text => <<"hello">>}),
    %% Session should now exist
    {ok, _} = agent_wire_session_store:get_session(SId),
    agent_wire_session_store:clear().

record_message_increments_count_test() ->
    SId = <<"msg-count-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"a">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"b">>}),
    ?assertEqual(2, agent_wire_session_store:message_count(SId)),
    agent_wire_session_store:clear().

record_messages_batch_test() ->
    SId = <<"msg-batch-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    Msgs = [
        #{type => text, text => <<"one">>},
        #{type => text, text => <<"two">>},
        #{type => text, text => <<"three">>}
    ],
    ok = agent_wire_session_store:record_messages(SId, Msgs),
    ?assertEqual(3, agent_wire_session_store:message_count(SId)),
    agent_wire_session_store:clear().

record_message_extracts_model_from_system_test() ->
    SId = <<"msg-model-sys-session">>,
    agent_wire_session_store:ensure_tables(),
    agent_wire_session_store:record_message(SId,
        #{type => system, system_info => #{model => <<"claude-opus-4-6">>}}),
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(<<"claude-opus-4-6">>, maps:get(model, Meta)),
    agent_wire_session_store:clear().

record_message_extracts_model_from_result_test() ->
    SId = <<"msg-model-res-session">>,
    agent_wire_session_store:ensure_tables(),
    agent_wire_session_store:record_message(SId,
        #{type => result, model => <<"claude-haiku">>}),
    {ok, Meta} = agent_wire_session_store:get_session(SId),
    ?assertEqual(<<"claude-haiku">>, maps:get(model, Meta)),
    agent_wire_session_store:clear().

%%====================================================================
%% get_session_messages/1
%%====================================================================

get_session_messages_in_order_test() ->
    SId = <<"msgs-order-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"first">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"second">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"third">>}),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId),
    ?assertEqual(3, length(Msgs)),
    [M1, M2, M3] = Msgs,
    ?assertEqual(<<"first">>, maps:get(text, M1)),
    ?assertEqual(<<"second">>, maps:get(text, M2)),
    ?assertEqual(<<"third">>, maps:get(text, M3)),
    agent_wire_session_store:clear().

get_session_messages_not_found_test() ->
    agent_wire_session_store:ensure_tables(),
    ?assertEqual({error, not_found},
        agent_wire_session_store:get_session_messages(<<"ghost-msg-session">>)),
    agent_wire_session_store:clear().

%%====================================================================
%% get_session_messages/2 with opts
%%====================================================================

get_session_messages_limit_test() ->
    SId = <<"msgs-limit-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        agent_wire_session_store:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 5)),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId, #{limit => 3}),
    ?assertEqual(3, length(Msgs)),
    agent_wire_session_store:clear().

get_session_messages_offset_test() ->
    SId = <<"msgs-offset-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        agent_wire_session_store:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 5)),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId, #{offset => 2}),
    ?assertEqual(3, length(Msgs)),
    [First | _] = Msgs,
    ?assertEqual(<<"3">>, maps:get(text, First)),
    agent_wire_session_store:clear().

get_session_messages_limit_and_offset_test() ->
    SId = <<"msgs-lo-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    lists:foreach(fun(I) ->
        Text = integer_to_binary(I),
        agent_wire_session_store:record_message(SId, #{type => text, text => Text})
    end, lists:seq(1, 10)),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId,
        #{offset => 3, limit => 2}),
    ?assertEqual(2, length(Msgs)),
    [M1, M2] = Msgs,
    ?assertEqual(<<"4">>, maps:get(text, M1)),
    ?assertEqual(<<"5">>, maps:get(text, M2)),
    agent_wire_session_store:clear().

get_session_messages_types_filter_test() ->
    SId = <<"msgs-types-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"t">>}),
    agent_wire_session_store:record_message(SId, #{type => result, text => <<"r">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"t2">>}),
    agent_wire_session_store:record_message(SId, #{type => system, text => <<"s">>}),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId,
        #{types => [text]}),
    ?assertEqual(2, length(Msgs)),
    Types = [maps:get(type, M) || M <- Msgs],
    ?assert(lists:all(fun(T) -> T =:= text end, Types)),
    agent_wire_session_store:clear().

get_session_messages_multiple_types_filter_test() ->
    SId = <<"msgs-mtypes-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"t">>}),
    agent_wire_session_store:record_message(SId, #{type => result, text => <<"r">>}),
    agent_wire_session_store:record_message(SId, #{type => system, text => <<"s">>}),
    {ok, Msgs} = agent_wire_session_store:get_session_messages(SId,
        #{types => [text, result]}),
    ?assertEqual(2, length(Msgs)),
    Types = lists:sort([maps:get(type, M) || M <- Msgs]),
    ?assertEqual([result, text], Types),
    agent_wire_session_store:clear().

%%====================================================================
%% session_count and message_count
%%====================================================================

session_count_empty_test() ->
    agent_wire_session_store:ensure_tables(),
    ?assertEqual(0, agent_wire_session_store:session_count()),
    agent_wire_session_store:clear().

session_count_test() ->
    agent_wire_session_store:register_session(<<"sc-1">>, #{adapter => claude}),
    agent_wire_session_store:register_session(<<"sc-2">>, #{adapter => gemini}),
    agent_wire_session_store:register_session(<<"sc-3">>, #{adapter => codex}),
    ?assertEqual(3, agent_wire_session_store:session_count()),
    agent_wire_session_store:clear().

message_count_no_messages_test() ->
    agent_wire_session_store:ensure_tables(),
    ?assertEqual(0, agent_wire_session_store:message_count(<<"no-msgs-session">>)),
    agent_wire_session_store:clear().

message_count_test() ->
    SId = <<"mc-session">>,
    agent_wire_session_store:register_session(SId, #{adapter => claude}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"a">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"b">>}),
    agent_wire_session_store:record_message(SId, #{type => text, text => <<"c">>}),
    ?assertEqual(3, agent_wire_session_store:message_count(SId)),
    agent_wire_session_store:clear().

message_count_isolated_per_session_test() ->
    SId1 = <<"mc-iso-1">>,
    SId2 = <<"mc-iso-2">>,
    agent_wire_session_store:register_session(SId1, #{adapter => claude}),
    agent_wire_session_store:register_session(SId2, #{adapter => claude}),
    agent_wire_session_store:record_message(SId1, #{type => text, text => <<"x">>}),
    agent_wire_session_store:record_message(SId1, #{type => text, text => <<"y">>}),
    agent_wire_session_store:record_message(SId2, #{type => text, text => <<"z">>}),
    ?assertEqual(2, agent_wire_session_store:message_count(SId1)),
    ?assertEqual(1, agent_wire_session_store:message_count(SId2)),
    agent_wire_session_store:clear().
