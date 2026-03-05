%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire (types, normalize_message,
%%%      parse_stop_reason, parse_permission_mode).
%%%
%%% Cross-referenced against TypeScript Agent SDK v0.2.66 to verify
%%% all wire protocol message types and enrichment fields are handled.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% normalize_message/1 — Basic types
%%====================================================================

normalize_text_test() ->
    Raw = #{<<"type">> => <<"text">>, <<"content">> => <<"hello">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(text, maps:get(type, Msg)),
    ?assertEqual(<<"hello">>, maps:get(content, Msg)),
    ?assert(is_integer(maps:get(timestamp, Msg))),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_error_test() ->
    Raw = #{<<"type">> => <<"error">>, <<"content">> => <<"oops">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(error, maps:get(type, Msg)),
    ?assertEqual(<<"oops">>, maps:get(content, Msg)).

normalize_system_test() ->
    Raw = #{<<"type">> => <<"system">>, <<"content">> => <<"init">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(system, maps:get(type, Msg)).

normalize_control_test() ->
    %% Legacy control type — still supported
    Raw = #{<<"type">> => <<"control">>, <<"method">> => <<"ping">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(control, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_unknown_type_test() ->
    Raw = #{<<"type">> => <<"unknown_future_type">>, <<"data">> => <<"x">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_no_type_field_test() ->
    Raw = #{<<"data">> => <<"mystery">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(raw, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_missing_content_defaults_test() ->
    Raw = #{<<"type">> => <<"text">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<>>, maps:get(content, Msg)).

%%====================================================================
%% normalize_message/1 — Common fields (uuid, session_id)
%%====================================================================

common_fields_uuid_test() ->
    Raw = #{<<"type">> => <<"text">>,
            <<"content">> => <<"hi">>,
            <<"uuid">> => <<"msg-uuid-123">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"msg-uuid-123">>, maps:get(uuid, Msg)).

common_fields_session_id_test() ->
    Raw = #{<<"type">> => <<"text">>,
            <<"content">> => <<"hi">>,
            <<"session_id">> => <<"sess-abc">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"sess-abc">>, maps:get(session_id, Msg)).

common_fields_both_test() ->
    Raw = #{<<"type">> => <<"text">>,
            <<"content">> => <<"hi">>,
            <<"uuid">> => <<"u1">>,
            <<"session_id">> => <<"s1">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"u1">>, maps:get(uuid, Msg)),
    ?assertEqual(<<"s1">>, maps:get(session_id, Msg)).

common_fields_absent_test() ->
    Raw = #{<<"type">> => <<"text">>, <<"content">> => <<"hi">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertNot(maps:is_key(uuid, Msg)),
    ?assertNot(maps:is_key(session_id, Msg)).

%%====================================================================
%% normalize_message/1 — Assistant messages
%%====================================================================

normalize_assistant_test() ->
    Raw = #{<<"type">> => <<"assistant">>,
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"hi">>}
            ]},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(assistant, maps:get(type, Msg)),
    Blocks = maps:get(content_blocks, Msg),
    ?assertEqual(1, length(Blocks)),
    [Block] = Blocks,
    ?assertEqual(text, maps:get(type, Block)),
    ?assertEqual(<<"hi">>, maps:get(text, Block)).

normalize_assistant_empty_content_test() ->
    Raw = #{<<"type">> => <<"assistant">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(assistant, maps:get(type, Msg)),
    ?assertEqual([], maps:get(content_blocks, Msg)).

normalize_assistant_with_beta_message_test() ->
    %% TS SDK wraps content in a "message" BetaMessage object
    Raw = #{<<"type">> => <<"assistant">>,
            <<"message">> => #{
                <<"content">> => [
                    #{<<"type">> => <<"text">>, <<"text">> => <<"from message">>}
                ],
                <<"model">> => <<"claude-sonnet-4-20250514">>,
                <<"id">> => <<"msg_abc123">>,
                <<"usage">> => #{<<"input_tokens">> => 50,
                                 <<"output_tokens">> => 20},
                <<"stop_reason">> => <<"end_turn">>
            }},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(assistant, maps:get(type, Msg)),
    Blocks = maps:get(content_blocks, Msg),
    ?assertEqual(1, length(Blocks)),
    ?assertEqual(<<"claude-sonnet-4-20250514">>, maps:get(model, Msg)),
    ?assertEqual(<<"msg_abc123">>, maps:get(message_id, Msg)),
    ?assertEqual(#{<<"input_tokens">> => 50, <<"output_tokens">> => 20},
                 maps:get(usage, Msg)),
    ?assertEqual(<<"end_turn">>, maps:get(stop_reason, Msg)),
    ?assertEqual(end_turn, maps:get(stop_reason_atom, Msg)).

normalize_assistant_null_message_test() ->
    %% JSON null for message field should not crash (OTP 27 null safety)
    Raw = #{<<"type">> => <<"assistant">>,
            <<"message">> => null,
            <<"content">> => [
                #{<<"type">> => <<"text">>, <<"text">> => <<"safe">>}
            ]},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(assistant, maps:get(type, Msg)),
    Blocks = maps:get(content_blocks, Msg),
    ?assertEqual(1, length(Blocks)).

normalize_assistant_parent_tool_use_id_test() ->
    Raw = #{<<"type">> => <<"assistant">>,
            <<"content">> => [],
            <<"parent_tool_use_id">> => <<"tu_parent_1">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"tu_parent_1">>, maps:get(parent_tool_use_id, Msg)).

normalize_assistant_error_info_test() ->
    Raw = #{<<"type">> => <<"assistant">>,
            <<"content">> => [],
            <<"error">> => #{<<"code">> => <<"rate_limit">>,
                             <<"message">> => <<"slow down">>}},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(#{<<"code">> => <<"rate_limit">>,
                   <<"message">> => <<"slow down">>},
                 maps:get(error_info, Msg)).

%%====================================================================
%% normalize_message/1 — Tool messages
%%====================================================================

normalize_tool_use_test() ->
    Raw = #{
        <<"type">> => <<"tool_use">>,
        <<"tool_name">> => <<"read_file">>,
        <<"tool_input">> => #{<<"path">> => <<"/tmp/test">>}
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"path">> => <<"/tmp/test">>}, maps:get(tool_input, Msg)).

normalize_tool_use_alt_keys_test() ->
    Raw = #{
        <<"type">> => <<"tool_use">>,
        <<"name">> => <<"bash">>,
        <<"input">> => #{<<"command">> => <<"ls">>}
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(tool_use, maps:get(type, Msg)),
    ?assertEqual(<<"bash">>, maps:get(tool_name, Msg)),
    ?assertEqual(#{<<"command">> => <<"ls">>}, maps:get(tool_input, Msg)).

normalize_missing_tool_fields_defaults_test() ->
    Raw = #{<<"type">> => <<"tool_use">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<>>, maps:get(tool_name, Msg)),
    ?assertEqual(#{}, maps:get(tool_input, Msg)).

normalize_tool_result_test() ->
    Raw = #{
        <<"type">> => <<"tool_result">>,
        <<"tool_name">> => <<"read_file">>,
        <<"content">> => <<"file contents">>
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(tool_result, maps:get(type, Msg)),
    ?assertEqual(<<"read_file">>, maps:get(tool_name, Msg)),
    ?assertEqual(<<"file contents">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_message/1 — Result messages (CRITICAL: "result" field fix)
%%====================================================================

normalize_result_content_field_test() ->
    %% Legacy format: "content" field
    Raw = #{<<"type">> => <<"result">>, <<"content">> => <<"done">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"done">>, maps:get(content, Msg)).

normalize_result_result_field_test() ->
    %% Correct TS SDK format: "result" field takes priority over "content"
    Raw = #{<<"type">> => <<"result">>,
            <<"result">> => <<"correct answer">>,
            <<"content">> => <<"wrong field">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"correct answer">>, maps:get(content, Msg)).

normalize_result_only_result_field_test() ->
    %% Only "result" field present (no "content")
    Raw = #{<<"type">> => <<"result">>,
            <<"result">> => <<"the answer">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"the answer">>, maps:get(content, Msg)).

normalize_result_enriched_test() ->
    Raw = #{
        <<"type">> => <<"result">>,
        <<"content">> => <<"done">>,
        <<"duration_ms">> => 1500,
        <<"num_turns">> => 3,
        <<"session_id">> => <<"sess-abc">>,
        <<"stop_reason">> => <<"end_turn">>,
        <<"usage">> => #{<<"input_tokens">> => 100, <<"output_tokens">> => 50},
        <<"total_cost_usd">> => 0.005,
        <<"is_error">> => false,
        <<"subtype">> => <<"success">>
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertEqual(<<"done">>, maps:get(content, Msg)),
    ?assertEqual(1500, maps:get(duration_ms, Msg)),
    ?assertEqual(3, maps:get(num_turns, Msg)),
    ?assertEqual(<<"sess-abc">>, maps:get(session_id, Msg)),
    ?assertEqual(<<"end_turn">>, maps:get(stop_reason, Msg)),
    ?assertEqual(end_turn, maps:get(stop_reason_atom, Msg)),
    ?assertEqual(#{<<"input_tokens">> => 100, <<"output_tokens">> => 50},
                 maps:get(usage, Msg)),
    ?assertEqual(0.005, maps:get(total_cost_usd, Msg)),
    ?assertEqual(false, maps:get(is_error, Msg)),
    ?assertEqual(<<"success">>, maps:get(subtype, Msg)).

normalize_result_with_errors_test() ->
    %% SDKResultError carries "errors" list
    Raw = #{<<"type">> => <<"result">>,
            <<"is_error">> => true,
            <<"subtype">> => <<"error">>,
            <<"errors">> => [<<"tool failed">>, <<"timeout">>]},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(true, maps:get(is_error, Msg)),
    ?assertEqual([<<"tool failed">>, <<"timeout">>], maps:get(errors, Msg)).

normalize_result_with_api_duration_test() ->
    Raw = #{<<"type">> => <<"result">>,
            <<"content">> => <<"ok">>,
            <<"duration_ms">> => 2000,
            <<"duration_api_ms">> => 1800,
            <<"modelUsage">> => #{<<"sonnet">> => #{<<"in">> => 500}}},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(2000, maps:get(duration_ms, Msg)),
    ?assertEqual(1800, maps:get(duration_api_ms, Msg)),
    ?assertEqual(#{<<"sonnet">> => #{<<"in">> => 500}},
                 maps:get(model_usage, Msg)).

normalize_result_minimal_test() ->
    Raw = #{<<"type">> => <<"result">>, <<"content">> => <<"ok">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(result, maps:get(type, Msg)),
    ?assertNot(maps:is_key(duration_ms, Msg)),
    ?assertNot(maps:is_key(num_turns, Msg)),
    ?assertNot(maps:is_key(usage, Msg)),
    ?assertNot(maps:is_key(stop_reason_atom, Msg)).

%%====================================================================
%% normalize_message/1 — Control protocol messages
%%====================================================================

normalize_control_request_test() ->
    Raw = #{
        <<"type">> => <<"control_request">>,
        <<"request_id">> => <<"req_1_abcd1234">>,
        <<"request">> => #{<<"subtype">> => <<"can_use_tool">>,
                           <<"tool_name">> => <<"Read">>}
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(control_request, maps:get(type, Msg)),
    ?assertEqual(<<"req_1_abcd1234">>, maps:get(request_id, Msg)),
    ?assertEqual(#{<<"subtype">> => <<"can_use_tool">>,
                   <<"tool_name">> => <<"Read">>}, maps:get(request, Msg)).

normalize_control_response_test() ->
    Raw = #{
        <<"type">> => <<"control_response">>,
        <<"request_id">> => <<"req_1_abcd1234">>,
        <<"response">> => #{<<"subtype">> => <<"success">>,
                            <<"session_id">> => <<"s123">>}
    },
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(control_response, maps:get(type, Msg)),
    ?assertEqual(<<"req_1_abcd1234">>, maps:get(request_id, Msg)),
    ?assertEqual(#{<<"subtype">> => <<"success">>,
                   <<"session_id">> => <<"s123">>}, maps:get(response, Msg)).

%%====================================================================
%% normalize_message/1 — Stream and thinking messages
%%====================================================================

normalize_stream_event_test() ->
    Raw = #{<<"type">> => <<"stream_event">>,
            <<"subtype">> => <<"content_block_start">>,
            <<"content">> => <<"partial">>,
            <<"parent_tool_use_id">> => <<"tu_1">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(stream_event, maps:get(type, Msg)),
    ?assertEqual(<<"content_block_start">>, maps:get(subtype, Msg)),
    ?assertEqual(<<"partial">>, maps:get(content, Msg)),
    ?assertEqual(<<"tu_1">>, maps:get(parent_tool_use_id, Msg)).

normalize_thinking_test() ->
    Raw = #{<<"type">> => <<"thinking">>,
            <<"thinking">> => <<"let me reason about this...">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(thinking, maps:get(type, Msg)),
    ?assertEqual(<<"let me reason about this...">>, maps:get(content, Msg)).

normalize_thinking_content_fallback_test() ->
    %% Falls back to "content" key if "thinking" absent
    Raw = #{<<"type">> => <<"thinking">>,
            <<"content">> => <<"fallback thinking">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"fallback thinking">>, maps:get(content, Msg)).

%%====================================================================
%% normalize_message/1 — User messages
%%====================================================================

normalize_user_message_test() ->
    Raw = #{<<"type">> => <<"user">>,
            <<"content">> => <<"hello claude">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(user, maps:get(type, Msg)),
    ?assertEqual(<<"hello claude">>, maps:get(content, Msg)).

normalize_user_with_parent_test() ->
    Raw = #{<<"type">> => <<"user">>,
            <<"content">> => <<"tool result">>,
            <<"parent_tool_use_id">> => <<"tu_1">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(<<"tu_1">>, maps:get(parent_tool_use_id, Msg)).

normalize_user_replay_test() ->
    Raw = #{<<"type">> => <<"user">>,
            <<"content">> => <<"replayed">>,
            <<"isReplay">> => true},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(true, maps:get(is_replay, Msg)).

normalize_user_not_replay_test() ->
    Raw = #{<<"type">> => <<"user">>,
            <<"content">> => <<"fresh">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertNot(maps:is_key(is_replay, Msg)).

normalize_user_replay_null_test() ->
    %% JSON null for isReplay should be treated as absent
    Raw = #{<<"type">> => <<"user">>,
            <<"content">> => <<"test">>,
            <<"isReplay">> => null},
    Msg = agent_wire:normalize_message(Raw),
    ?assertNot(maps:is_key(is_replay, Msg)).

%%====================================================================
%% normalize_message/1 — Tool progress and summary
%%====================================================================

normalize_tool_progress_test() ->
    Raw = #{<<"type">> => <<"tool_progress">>,
            <<"content">> => <<"50% complete">>,
            <<"tool_name">> => <<"Bash">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(tool_progress, maps:get(type, Msg)),
    ?assertEqual(<<"50% complete">>, maps:get(content, Msg)),
    ?assertEqual(<<"Bash">>, maps:get(tool_name, Msg)).

normalize_tool_use_summary_test() ->
    Raw = #{<<"type">> => <<"tool_use_summary">>,
            <<"content">> => <<"Read 3 files">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(tool_use_summary, maps:get(type, Msg)),
    ?assertEqual(<<"Read 3 files">>, maps:get(content, Msg)).

normalize_prompt_suggestion_test() ->
    Raw = #{<<"type">> => <<"prompt_suggestion">>,
            <<"content">> => <<"Try asking about tests">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(prompt_suggestion, maps:get(type, Msg)),
    ?assertEqual(<<"Try asking about tests">>, maps:get(content, Msg)).

normalize_auth_status_test() ->
    Raw = #{<<"type">> => <<"auth_status">>,
            <<"status">> => <<"authenticated">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(auth_status, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_rate_limit_event_test() ->
    Raw = #{<<"type">> => <<"rate_limit_event">>,
            <<"retry_after">> => 30},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(rate_limit_event, maps:get(type, Msg)),
    ?assertEqual(Raw, maps:get(raw, Msg)).

normalize_rate_limit_event_structured_test() ->
    Raw = #{<<"type">> => <<"rate_limit_event">>,
            <<"status">> => <<"allowed_warning">>,
            <<"resetsAt">> => 1709550000,
            <<"rateLimitType">> => <<"five_hour">>,
            <<"utilization">> => 0.85,
            <<"overageStatus">> => <<"allowed">>,
            <<"overageResetsAt">> => 1709560000,
            <<"isUsingOverage">> => true,
            <<"surpassedThreshold">> => 0.8},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(rate_limit_event, maps:get(type, Msg)),
    ?assertEqual(<<"allowed_warning">>, maps:get(rate_limit_status, Msg)),
    ?assertEqual(1709550000, maps:get(resets_at, Msg)),
    ?assertEqual(<<"five_hour">>, maps:get(rate_limit_type, Msg)),
    ?assertEqual(0.85, maps:get(utilization, Msg)),
    ?assertEqual(<<"allowed">>, maps:get(overage_status, Msg)),
    ?assertEqual(1709560000, maps:get(overage_resets_at, Msg)),
    ?assertEqual(true, maps:get(is_using_overage, Msg)),
    ?assertEqual(0.8, maps:get(surpassed_threshold, Msg)).

normalize_rate_limit_event_minimal_test() ->
    %% Rate limit with only status — other fields are optional
    Raw = #{<<"type">> => <<"rate_limit_event">>,
            <<"status">> => <<"rejected">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(rate_limit_event, maps:get(type, Msg)),
    ?assertEqual(<<"rejected">>, maps:get(rate_limit_status, Msg)),
    %% Optional fields should not be present
    ?assertNot(maps:is_key(resets_at, Msg)),
    ?assertNot(maps:is_key(utilization, Msg)).

%%====================================================================
%% normalize_message/1 — System init parsing
%%====================================================================

normalize_system_init_test() ->
    Raw = #{<<"type">> => <<"system">>,
            <<"subtype">> => <<"init">>,
            <<"content">> => <<"ready">>,
            <<"tools">> => [<<"Read">>, <<"Write">>],
            <<"model">> => <<"claude-sonnet-4-20250514">>,
            <<"mcp_servers">> => [#{<<"name">> => <<"fs">>}],
            <<"permissionMode">> => <<"default">>,
            <<"claude_code_version">> => <<"2.1.66">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertEqual(system, maps:get(type, Msg)),
    ?assertEqual(<<"init">>, maps:get(subtype, Msg)),
    ?assert(maps:is_key(system_info, Msg)),
    SysInfo = maps:get(system_info, Msg),
    ?assertEqual([<<"Read">>, <<"Write">>], maps:get(tools, SysInfo)),
    ?assertEqual(<<"claude-sonnet-4-20250514">>, maps:get(model, SysInfo)),
    ?assertEqual([#{<<"name">> => <<"fs">>}], maps:get(mcp_servers, SysInfo)),
    ?assertEqual(<<"default">>, maps:get(permission_mode, SysInfo)),
    ?assertEqual(<<"2.1.66">>, maps:get(claude_code_version, SysInfo)).

normalize_system_non_init_test() ->
    %% Non-init system messages should not have system_info
    Raw = #{<<"type">> => <<"system">>,
            <<"subtype">> => <<"status">>,
            <<"content">> => <<"ok">>},
    Msg = agent_wire:normalize_message(Raw),
    ?assertNot(maps:is_key(system_info, Msg)).

normalize_system_init_minimal_test() ->
    %% Init with only some fields — missing ones should be absent
    Raw = #{<<"type">> => <<"system">>,
            <<"subtype">> => <<"init">>,
            <<"content">> => <<"ready">>,
            <<"model">> => <<"claude-haiku-4-5-20251001">>},
    Msg = agent_wire:normalize_message(Raw),
    SysInfo = maps:get(system_info, Msg),
    ?assertEqual(<<"claude-haiku-4-5-20251001">>, maps:get(model, SysInfo)),
    ?assertNot(maps:is_key(tools, SysInfo)),
    ?assertNot(maps:is_key(mcp_servers, SysInfo)).

%%====================================================================
%% make_request_id/0
%%====================================================================

make_request_id_format_test() ->
    Id = agent_wire:make_request_id(),
    ?assert(is_binary(Id)),
    ?assertMatch(<<"req_", _/binary>>, Id),
    Parts = binary:split(Id, <<"_">>, [global]),
    ?assertEqual(3, length(Parts)),
    [<<"req">>, _Counter, Hex] = Parts,
    ?assertEqual(8, byte_size(Hex)).

make_request_id_unique_test() ->
    Ids = [agent_wire:make_request_id() || _ <- lists:seq(1, 100)],
    UniqueIds = lists:usort(Ids),
    ?assertEqual(length(Ids), length(UniqueIds)).

make_request_id_monotonic_test() ->
    Id1 = agent_wire:make_request_id(),
    Id2 = agent_wire:make_request_id(),
    [<<"req">>, N1Bin, _] = binary:split(Id1, <<"_">>, [global]),
    [<<"req">>, N2Bin, _] = binary:split(Id2, <<"_">>, [global]),
    N1 = binary_to_integer(N1Bin),
    N2 = binary_to_integer(N2Bin),
    ?assert(N2 > N1).

%%====================================================================
%% parse_stop_reason/1
%%====================================================================

parse_stop_reason_end_turn_test() ->
    ?assertEqual(end_turn, agent_wire:parse_stop_reason(<<"end_turn">>)).

parse_stop_reason_max_tokens_test() ->
    ?assertEqual(max_tokens, agent_wire:parse_stop_reason(<<"max_tokens">>)).

parse_stop_reason_stop_sequence_test() ->
    ?assertEqual(stop_sequence, agent_wire:parse_stop_reason(<<"stop_sequence">>)).

parse_stop_reason_refusal_test() ->
    ?assertEqual(refusal, agent_wire:parse_stop_reason(<<"refusal">>)).

parse_stop_reason_tool_use_test() ->
    ?assertEqual(tool_use_stop, agent_wire:parse_stop_reason(<<"tool_use">>)).

parse_stop_reason_unknown_test() ->
    ?assertEqual(unknown_stop, agent_wire:parse_stop_reason(<<"future_reason">>)).

parse_stop_reason_non_binary_test() ->
    ?assertEqual(unknown_stop, agent_wire:parse_stop_reason(undefined)),
    ?assertEqual(unknown_stop, agent_wire:parse_stop_reason(42)).

%%====================================================================
%% parse_permission_mode/1
%%====================================================================

parse_permission_mode_default_test() ->
    ?assertEqual(default, agent_wire:parse_permission_mode(<<"default">>)).

parse_permission_mode_accept_edits_test() ->
    ?assertEqual(accept_edits, agent_wire:parse_permission_mode(<<"acceptEdits">>)).

parse_permission_mode_bypass_test() ->
    ?assertEqual(bypass_permissions,
                 agent_wire:parse_permission_mode(<<"bypassPermissions">>)).

parse_permission_mode_plan_test() ->
    ?assertEqual(plan, agent_wire:parse_permission_mode(<<"plan">>)).

parse_permission_mode_dont_ask_test() ->
    ?assertEqual(dont_ask, agent_wire:parse_permission_mode(<<"dontAsk">>)).

parse_permission_mode_unknown_test() ->
    ?assertEqual(default, agent_wire:parse_permission_mode(<<"future_mode">>)).

parse_permission_mode_non_binary_test() ->
    ?assertEqual(default, agent_wire:parse_permission_mode(undefined)).

%%====================================================================
%% Timestamp verification
%%====================================================================

timestamp_present_test() ->
    Raw = #{<<"type">> => <<"text">>, <<"content">> => <<"test">>},
    Msg = agent_wire:normalize_message(Raw),
    Ts = maps:get(timestamp, Msg),
    ?assert(is_integer(Ts)),
    Now = erlang:system_time(millisecond),
    ?assert(Now - Ts < 10000).
