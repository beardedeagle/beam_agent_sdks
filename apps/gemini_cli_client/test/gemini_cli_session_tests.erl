%%%-------------------------------------------------------------------
%%% @doc EUnit tests for gemini_cli_session gen_statem.
%%%
%%% Uses mock shell scripts that emit JSONL output and exit.
%%% Tests cover:
%%%   - Health state transitions
%%%   - Query lifecycle (JSONL output + exit_status 0)
%%%   - Sequential queries (new port each)
%%%   - session_id captured from init event
%%%   - Session info
%%%   - Set model at runtime
%%%   - Interrupt
%%%   - send_control → not_supported
%%%   - Error handling (bad path, wrong ref, concurrent query)
%%%   - Exit code error handling
%%% @end
%%%-------------------------------------------------------------------
-module(gemini_cli_session_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% API contract tests (no setup needed)
%%====================================================================

child_spec_test() ->
    Spec = gemini_cli_client:child_spec(#{cli_path => "/usr/bin/gemini"}),
    ?assertEqual(gemini_cli_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)),
    {Mod, Fun, Args} = maps:get(start, Spec),
    ?assertEqual(gemini_cli_session, Mod),
    ?assertEqual(start_link, Fun),
    ?assertEqual([#{cli_path => "/usr/bin/gemini"}], Args).

send_control_not_supported_test() ->
    ?assertEqual({error, not_supported},
                 gemini_cli_session:send_control(self(), <<"foo">>, #{})).

set_permission_mode_not_supported_test() ->
    ?assertEqual({error, not_supported},
                 gemini_cli_session:set_permission_mode(self(), <<"default">>)).

%%====================================================================
%% Mock script-based integration tests
%%====================================================================

mock_session_test_() ->
    {"gemini_cli_session lifecycle with mock CLI",
     {setup,
      fun setup_mock_session/0,
      fun cleanup_mock/1,
      fun(ScriptPath) -> [
          {"health reports ready in idle state",
           {timeout, 10, fun() -> test_health(ScriptPath) end}},
          {"query collects all messages",
           {timeout, 10, fun() -> test_query(ScriptPath) end}},
          {"sequential queries work (new port each)",
           {timeout, 15, fun() -> test_sequential_queries(ScriptPath) end}},
          {"session_id captured from init event",
           {timeout, 10, fun() -> test_session_id_capture(ScriptPath) end}},
          {"session_info returns transport info",
           {timeout, 10, fun() -> test_session_info(ScriptPath) end}},
          {"set_model stores model",
           {timeout, 10, fun() -> test_set_model(ScriptPath) end}},
          {"interrupt closes port",
           {timeout, 10, fun() -> test_interrupt(ScriptPath) end}},
          {"wrong ref rejected",
           {timeout, 10, fun() -> test_wrong_ref(ScriptPath) end}},
          {"concurrent query rejected",
           {timeout, 10, fun() -> test_concurrent_query(ScriptPath) end}},
          {"gemini_cli_client:query/2 collects all messages",
           {timeout, 15, fun() -> test_sdk_query(ScriptPath) end}},
          {"child_spec correctness",
           {timeout, 5, fun() -> test_child_spec(ScriptPath) end}}
      ] end}}.

setup_mock_session() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_gemini_session_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_session_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

cleanup_mock(ScriptPath) ->
    file:delete(ScriptPath).

%% Mock script emitting a realistic Gemini CLI JSONL stream.
mock_session_script() ->
    <<
      "#!/bin/sh\n"
      "exec 2>/dev/null\n"
      "# Mock Gemini CLI — emit JSONL stream and exit\n"
      "# Ignore all args, emit fixed output\n"
      "echo '{\"type\":\"init\",\"session_id\":\"gemini-sess-001\",\"model\":\"gemini-2.0-flash\"}'\n"
      "echo '{\"type\":\"message\",\"role\":\"user\",\"content\":\"test prompt\"}'\n"
      "echo '{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Hello\",\"delta\":true}'\n"
      "echo '{\"type\":\"message\",\"role\":\"assistant\",\"content\":\" world\",\"delta\":true}'\n"
      "echo '{\"type\":\"tool_use\",\"tool_name\":\"Read\",\"parameters\":{\"path\":\"/tmp/test\"},\"tool_id\":\"tool-001\"}'\n"
      "echo '{\"type\":\"tool_result\",\"status\":\"success\",\"output\":\"file contents\",\"tool_id\":\"tool-001\"}'\n"
      "echo '{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"Done!\",\"delta\":true}'\n"
      "echo '{\"type\":\"result\",\"status\":\"success\",\"stats\":{\"tokens_in\":10,\"tokens_out\":20,\"duration_ms\":500,\"tool_calls\":1}}'\n"
      "exit 0\n"
    >>.

test_health(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    ?assertEqual(ready, gemini_cli_session:health(Pid)),
    gemini_cli_session:stop(Pid).

test_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"What is 2+2?">>, #{}, 10000),
    ?assert(is_reference(Ref)),

    Messages = collect_all(Pid, Ref, []),
    ?assert(length(Messages) >= 1),

    %% Should have text and/or result messages
    Types = [maps:get(type, M) || M <- Messages],
    ?assert(lists:member(text, Types) orelse lists:member(result, Types)),

    gemini_cli_session:stop(Pid).

test_sequential_queries(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),

    %% First query
    {ok, Ref1} = gemini_cli_session:send_query(Pid, <<"query1">>, #{}, 10000),
    _Msgs1 = collect_all(Pid, Ref1, []),

    %% Wait for idle state
    timer:sleep(200),
    ?assertEqual(ready, gemini_cli_session:health(Pid)),

    %% Second query
    {ok, Ref2} = gemini_cli_session:send_query(Pid, <<"query2">>, #{}, 10000),
    _Msgs2 = collect_all(Pid, Ref2, []),

    timer:sleep(200),
    ?assertEqual(ready, gemini_cli_session:health(Pid)),
    gemini_cli_session:stop(Pid).

test_session_id_capture(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, Ref} = gemini_cli_session:send_query(Pid, <<"test">>, #{}, 10000),
    _Msgs = collect_all(Pid, Ref, []),

    %% After query completes, session_id should have been captured from init event
    timer:sleep(200),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assertEqual(<<"gemini-sess-001">>, maps:get(session_id, Info)),
    gemini_cli_session:stop(Pid).

test_session_info(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assert(is_map(Info)),
    ?assertEqual(gemini_cli, maps:get(transport, Info)),
    gemini_cli_session:stop(Pid).

test_set_model(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, <<"gemini-1.5-pro">>} = gemini_cli_session:set_model(Pid, <<"gemini-1.5-pro">>),
    {ok, Info} = gemini_cli_session:session_info(Pid),
    ?assertEqual(<<"gemini-1.5-pro">>, maps:get(model, Info)),
    gemini_cli_session:stop(Pid).

test_interrupt(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref} = gemini_cli_session:send_query(Pid, <<"test">>, #{}, 10000),
    ?assertEqual(ok, gemini_cli_session:interrupt(Pid)),
    timer:sleep(200),
    ?assertEqual(ready, gemini_cli_session:health(Pid)),
    gemini_cli_session:stop(Pid).

test_wrong_ref(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref} = gemini_cli_session:send_query(Pid, <<"test">>, #{}, 10000),
    WrongRef = make_ref(),
    ?assertEqual({error, bad_ref},
                 gemini_cli_session:receive_message(Pid, WrongRef, 1000)),
    catch gemini_cli_session:stop(Pid).

test_concurrent_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, _Ref1} = gemini_cli_session:send_query(Pid, <<"query1">>, #{}, 10000),
    Result = gemini_cli_session:send_query(Pid, <<"query2">>, #{}, 1000),
    ?assertEqual({error, query_in_progress}, Result),
    catch gemini_cli_session:stop(Pid).

test_sdk_query(ScriptPath) ->
    {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
    {ok, Messages} = gemini_cli_client:query(Pid, <<"What is 2+2?">>),
    ?assert(is_list(Messages)),
    ?assert(length(Messages) >= 1),
    gemini_cli_session:stop(Pid).

test_child_spec(ScriptPath) ->
    Spec = gemini_cli_client:child_spec(#{cli_path => ScriptPath}),
    ?assertEqual(gemini_cli_session, maps:get(id, Spec)),
    ?assertEqual(transient, maps:get(restart, Spec)),
    ?assertEqual(worker, maps:get(type, Spec)).

%%====================================================================
%% Error handling tests
%%====================================================================

bad_cli_path_test_() ->
    {"start_link with nonexistent CLI starts ok (fails on query)",
     {timeout, 10,
      fun() ->
          _ = application:ensure_all_started(telemetry),
          %% gemini_cli_session starts in idle; port opened per-query
          {ok, Pid} = gemini_cli_session:start_link(#{
              cli_path => "/nonexistent/path/to/gemini_that_doesnt_exist"
          }),
          ?assertEqual(ready, gemini_cli_session:health(Pid)),
          %% Query should fail when trying to open port
          Result = gemini_cli_session:send_query(Pid, <<"test">>, #{}, 5000),
          ?assertMatch({error, {open_port_failed, _}}, Result),
          gemini_cli_session:stop(Pid)
      end}}.

exit_code_error_test_() ->
    {"abnormal exit code produces error message",
     {setup,
      fun setup_error_script/0,
      fun cleanup_mock/1,
      fun(ScriptPath) ->
          [{timeout, 10, fun() ->
              _ = application:ensure_all_started(telemetry),
              {ok, Pid} = gemini_cli_session:start_link(#{cli_path => ScriptPath}),
              {ok, Ref} = gemini_cli_session:send_query(Pid, <<"test">>, #{}, 10000),
              Messages = collect_all(Pid, Ref, []),
              %% Should include an error message (from error event or exit code)
              Types = [maps:get(type, M) || M <- Messages],
              ?assert(lists:member(error, Types)),
              catch gemini_cli_session:stop(Pid)
          end}]
      end}}.

setup_error_script() ->
    _ = application:ensure_all_started(telemetry),
    ScriptPath = "/tmp/mock_gemini_error_" ++ integer_to_list(
        erlang:unique_integer([positive])),
    Script = mock_error_script(),
    ok = file:write_file(ScriptPath, Script),
    os:cmd("chmod +x " ++ ScriptPath),
    ScriptPath.

mock_error_script() ->
    <<
      "#!/bin/sh\n"
      "# Mock Gemini CLI — emit error and exit with non-zero code\n"
      "echo '{\"type\":\"init\",\"session_id\":\"err-sess\",\"model\":\"gemini-2.0-flash\"}'\n"
      "echo '{\"type\":\"error\",\"severity\":\"error\",\"message\":\"something went wrong\"}'\n"
      "exit 42\n"
    >>.

%%====================================================================
%% Helpers
%%====================================================================

collect_all(Pid, Ref, Acc) ->
    case gemini_cli_session:receive_message(Pid, Ref, 5000) of
        {ok, #{type := result} = Msg} ->
            lists:reverse([Msg | Acc]);
        {ok, #{type := error} = Msg} ->
            lists:reverse([Msg | Acc]);
        {ok, Msg} ->
            collect_all(Pid, Ref, [Msg | Acc]);
        {error, complete} ->
            lists:reverse(Acc);
        {error, _} ->
            lists:reverse(Acc)
    end.
