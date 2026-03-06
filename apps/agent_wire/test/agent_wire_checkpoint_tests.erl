%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire_checkpoint (file snapshot/rewind).
%%%
%%% Tests cover:
%%%   - Table lifecycle (ensure_table, clear)
%%%   - Snapshot creation with real temp files
%%%   - Rewind: restore existing files, delete non-existent-at-checkpoint files
%%%   - Rewind: {error, not_found} for unknown UUID
%%%   - list_checkpoints: newest first ordering
%%%   - get_checkpoint: found and not_found
%%%   - delete_checkpoint
%%%   - extract_file_paths: Write, Edit, write, edit, unknown tools
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_checkpoint_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Table lifecycle tests
%%====================================================================

ensure_table_idempotent_test() ->
    ok = agent_wire_checkpoint:ensure_table(),
    ok = agent_wire_checkpoint:ensure_table(),
    ok = agent_wire_checkpoint:ensure_table(),
    agent_wire_checkpoint:clear().

clear_removes_all_data_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-clear-test">>,
    UUID = <<"uuid-clear-1">>,
    Path = tmp_path("clear_test"),
    write_tmp(Path, <<"data">>),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    {ok, [_]} = agent_wire_checkpoint:list_checkpoints(SessionId),
    ok = agent_wire_checkpoint:clear(),
    {ok, []} = agent_wire_checkpoint:list_checkpoints(SessionId),
    file:delete(Path).

%%====================================================================
%% Snapshot tests
%%====================================================================

snapshot_existing_file_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-snap-1">>,
    UUID = <<"uuid-snap-1">>,
    Path = tmp_path("snap_existing"),
    write_tmp(Path, <<"original content">>),
    {ok, CP} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    ?assertEqual(UUID, maps:get(uuid, CP)),
    ?assertEqual(SessionId, maps:get(session_id, CP)),
    ?assert(is_integer(maps:get(created_at, CP))),
    [FileSnap] = maps:get(files, CP),
    ?assertEqual(list_to_binary(Path), maps:get(path, FileSnap)),
    ?assertEqual(true, maps:get(existed, FileSnap)),
    ?assertEqual(<<"original content">>, maps:get(content, FileSnap)),
    file:delete(Path),
    agent_wire_checkpoint:clear().

snapshot_nonexistent_file_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-snap-2">>,
    UUID = <<"uuid-snap-2">>,
    Path = tmp_path("snap_nonexistent_ghost"),
    %% File does NOT exist
    {ok, CP} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    [FileSnap] = maps:get(files, CP),
    ?assertEqual(false, maps:get(existed, FileSnap)),
    ?assertEqual(undefined, maps:get(content, FileSnap)),
    agent_wire_checkpoint:clear().

snapshot_multiple_files_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-snap-3">>,
    UUID = <<"uuid-snap-3">>,
    Path1 = tmp_path("snap_multi_a"),
    Path2 = tmp_path("snap_multi_b"),
    write_tmp(Path1, <<"file one">>),
    write_tmp(Path2, <<"file two">>),
    {ok, CP} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path1, Path2]),
    ?assertEqual(2, length(maps:get(files, CP))),
    file:delete(Path1),
    file:delete(Path2),
    agent_wire_checkpoint:clear().

snapshot_string_path_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-snap-4">>,
    UUID = <<"uuid-snap-4">>,
    Path = tmp_path("snap_string_path"),
    write_tmp(Path, <<"string path content">>),
    %% Pass as string (not binary) — must work
    {ok, CP} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    [FileSnap] = maps:get(files, CP),
    ?assertEqual(true, maps:get(existed, FileSnap)),
    file:delete(Path),
    agent_wire_checkpoint:clear().

%%====================================================================
%% Rewind tests
%%====================================================================

rewind_restores_file_content_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-rewind-1">>,
    UUID = <<"uuid-rewind-1">>,
    Path = tmp_path("rewind_restore"),
    write_tmp(Path, <<"original">>),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    %% Mutate the file
    write_tmp(Path, <<"mutated">>),
    ?assertEqual({ok, <<"mutated">>}, file:read_file(Path)),
    ok = agent_wire_checkpoint:rewind(SessionId, UUID),
    ?assertEqual({ok, <<"original">>}, file:read_file(Path)),
    file:delete(Path),
    agent_wire_checkpoint:clear().

rewind_deletes_file_not_at_checkpoint_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-rewind-2">>,
    UUID = <<"uuid-rewind-2">>,
    Path = tmp_path("rewind_new_file"),
    %% Snapshot when file does NOT exist
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    %% Create the file after snapshot
    write_tmp(Path, <<"created after checkpoint">>),
    ?assert(filelib:is_regular(Path)),
    ok = agent_wire_checkpoint:rewind(SessionId, UUID),
    %% File should be deleted
    ?assertEqual(false, filelib:is_regular(Path)),
    agent_wire_checkpoint:clear().

rewind_not_found_test() ->
    agent_wire_checkpoint:ensure_table(),
    Result = agent_wire_checkpoint:rewind(<<"sess-no">>, <<"uuid-no">>),
    ?assertEqual({error, not_found}, Result),
    agent_wire_checkpoint:clear().

%%====================================================================
%% list_checkpoints tests
%%====================================================================

list_checkpoints_empty_test() ->
    agent_wire_checkpoint:ensure_table(),
    {ok, List} = agent_wire_checkpoint:list_checkpoints(<<"sess-empty-list">>),
    ?assertEqual([], List),
    agent_wire_checkpoint:clear().

list_checkpoints_newest_first_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-list-order">>,
    Path = tmp_path("list_order"),
    write_tmp(Path, <<"x">>),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, <<"uuid-a">>, [Path]),
    %% Small sleep to ensure distinct timestamps
    timer:sleep(5),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, <<"uuid-b">>, [Path]),
    timer:sleep(5),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, <<"uuid-c">>, [Path]),
    {ok, List} = agent_wire_checkpoint:list_checkpoints(SessionId),
    ?assertEqual(3, length(List)),
    [First, Second, Third] = List,
    ?assert(maps:get(created_at, First) >= maps:get(created_at, Second)),
    ?assert(maps:get(created_at, Second) >= maps:get(created_at, Third)),
    file:delete(Path),
    agent_wire_checkpoint:clear().

list_checkpoints_only_own_session_test() ->
    agent_wire_checkpoint:ensure_table(),
    Path = tmp_path("list_session_isolation"),
    write_tmp(Path, <<"y">>),
    {ok, _} = agent_wire_checkpoint:snapshot(<<"sess-A">>, <<"uuid-A1">>, [Path]),
    {ok, _} = agent_wire_checkpoint:snapshot(<<"sess-B">>, <<"uuid-B1">>, [Path]),
    {ok, ListA} = agent_wire_checkpoint:list_checkpoints(<<"sess-A">>),
    {ok, ListB} = agent_wire_checkpoint:list_checkpoints(<<"sess-B">>),
    ?assertEqual(1, length(ListA)),
    ?assertEqual(1, length(ListB)),
    ?assertEqual(<<"uuid-A1">>, maps:get(uuid, hd(ListA))),
    ?assertEqual(<<"uuid-B1">>, maps:get(uuid, hd(ListB))),
    file:delete(Path),
    agent_wire_checkpoint:clear().

%%====================================================================
%% get_checkpoint tests
%%====================================================================

get_checkpoint_found_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-get-1">>,
    UUID = <<"uuid-get-1">>,
    Path = tmp_path("get_found"),
    write_tmp(Path, <<"get me">>),
    {ok, Snap} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    {ok, Got} = agent_wire_checkpoint:get_checkpoint(SessionId, UUID),
    ?assertEqual(Snap, Got),
    file:delete(Path),
    agent_wire_checkpoint:clear().

get_checkpoint_not_found_test() ->
    agent_wire_checkpoint:ensure_table(),
    Result = agent_wire_checkpoint:get_checkpoint(<<"sess-no">>, <<"uuid-no">>),
    ?assertEqual({error, not_found}, Result),
    agent_wire_checkpoint:clear().

%%====================================================================
%% delete_checkpoint tests
%%====================================================================

delete_checkpoint_test() ->
    agent_wire_checkpoint:ensure_table(),
    SessionId = <<"sess-del-1">>,
    UUID = <<"uuid-del-1">>,
    Path = tmp_path("delete_cp"),
    write_tmp(Path, <<"delete me">>),
    {ok, _} = agent_wire_checkpoint:snapshot(SessionId, UUID, [Path]),
    {ok, _} = agent_wire_checkpoint:get_checkpoint(SessionId, UUID),
    ok = agent_wire_checkpoint:delete_checkpoint(SessionId, UUID),
    ?assertEqual({error, not_found},
        agent_wire_checkpoint:get_checkpoint(SessionId, UUID)),
    file:delete(Path),
    agent_wire_checkpoint:clear().

delete_checkpoint_nonexistent_is_ok_test() ->
    agent_wire_checkpoint:ensure_table(),
    ok = agent_wire_checkpoint:delete_checkpoint(<<"sess-x">>, <<"uuid-x">>),
    agent_wire_checkpoint:clear().

%%====================================================================
%% extract_file_paths tests
%%====================================================================

extract_file_paths_write_tool_test() ->
    Input = #{<<"file_path">> => <<"/tmp/foo.txt">>},
    ?assertEqual([<<"/tmp/foo.txt">>],
        agent_wire_checkpoint:extract_file_paths(<<"Write">>, Input)).

extract_file_paths_edit_tool_test() ->
    Input = #{<<"file_path">> => <<"/tmp/bar.txt">>},
    ?assertEqual([<<"/tmp/bar.txt">>],
        agent_wire_checkpoint:extract_file_paths(<<"Edit">>, Input)).

extract_file_paths_lowercase_write_test() ->
    Input = #{<<"file_path">> => <<"/tmp/baz.txt">>},
    ?assertEqual([<<"/tmp/baz.txt">>],
        agent_wire_checkpoint:extract_file_paths(<<"write">>, Input)).

extract_file_paths_lowercase_edit_test() ->
    Input = #{<<"file_path">> => <<"/tmp/qux.txt">>},
    ?assertEqual([<<"/tmp/qux.txt">>],
        agent_wire_checkpoint:extract_file_paths(<<"edit">>, Input)).

extract_file_paths_atom_key_test() ->
    %% Supports atom key fallback
    Input = #{file_path => <<"/tmp/atom.txt">>},
    ?assertEqual([<<"/tmp/atom.txt">>],
        agent_wire_checkpoint:extract_file_paths(<<"Write">>, Input)).

extract_file_paths_unknown_tool_test() ->
    Input = #{<<"file_path">> => <<"/tmp/x.txt">>},
    ?assertEqual([],
        agent_wire_checkpoint:extract_file_paths(<<"Read">>, Input)).

extract_file_paths_bash_tool_test() ->
    Input = #{<<"command">> => <<"ls -la">>},
    ?assertEqual([],
        agent_wire_checkpoint:extract_file_paths(<<"Bash">>, Input)).

extract_file_paths_no_file_path_key_test() ->
    Input = #{<<"other_key">> => <<"value">>},
    ?assertEqual([],
        agent_wire_checkpoint:extract_file_paths(<<"Write">>, Input)).

extract_file_paths_non_map_input_test() ->
    ?assertEqual([],
        agent_wire_checkpoint:extract_file_paths(<<"Write">>, not_a_map)).

%%====================================================================
%% Helpers
%%====================================================================

tmp_path(Name) ->
    Pid = pid_to_list(self()),
    SafePid = re:replace(Pid, "[<>.]", "_", [global, {return, list}]),
    "/tmp/agent_wire_checkpoint_tests_" ++ SafePid ++ "_" ++ Name.

write_tmp(Path, Content) ->
    ok = file:write_file(Path, Content).
