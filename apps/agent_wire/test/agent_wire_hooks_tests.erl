%%%-------------------------------------------------------------------
%%% @doc EUnit tests for agent_wire_hooks.
%%%
%%% Covers:
%%%   - Constructors (hook/2, hook/3)
%%%   - Registry (new_registry, register_hook, register_hooks)
%%%   - Dispatch — notification-only events (ignore deny)
%%%   - Dispatch — blocking events (first deny wins)
%%%   - Matchers (exact, regex, no matcher)
%%%   - Crash protection (callback crash/throw)
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_hooks_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Constructor Tests
%%====================================================================

hook_2_creates_valid_def_test() ->
    Cb = fun(_) -> ok end,
    H = agent_wire_hooks:hook(pre_tool_use, Cb),
    ?assertEqual(pre_tool_use, maps:get(event, H)),
    ?assertEqual(Cb, maps:get(callback, H)),
    ?assertNot(maps:is_key(matcher, H)).

hook_3_creates_def_with_matcher_test() ->
    Cb = fun(_) -> ok end,
    Matcher = #{tool_name => <<"Bash">>},
    H = agent_wire_hooks:hook(pre_tool_use, Cb, Matcher),
    ?assertEqual(pre_tool_use, maps:get(event, H)),
    ?assertEqual(Cb, maps:get(callback, H)),
    ?assertEqual(Matcher, maps:get(matcher, H)).

all_six_event_types_accepted_test_() ->
    Events = [pre_tool_use, post_tool_use, stop,
              session_start, session_end, user_prompt_submit],
    [{"event " ++ atom_to_list(E),
      fun() ->
          H = agent_wire_hooks:hook(E, fun(_) -> ok end),
          ?assertEqual(E, maps:get(event, H))
      end} || E <- Events].

%%====================================================================
%% Registry Tests
%%====================================================================

new_registry_returns_empty_map_test() ->
    ?assertEqual(#{}, agent_wire_hooks:new_registry()).

register_hook_adds_under_event_test() ->
    H = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual([H], maps:get(pre_tool_use, Reg)).

register_hooks_registers_multiple_test() ->
    H1 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    H2 = agent_wire_hooks:hook(stop, fun(_) -> ok end),
    H3 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2, H3], agent_wire_hooks:new_registry()),
    ?assertEqual(2, length(maps:get(pre_tool_use, Reg))),
    ?assertEqual(1, length(maps:get(stop, Reg))).

multiple_hooks_per_event_preserved_in_order_test() ->
    %% Verify hooks fire in registration order.
    %% Registry stores reversed (prepend = O(1)); fire/3 reverses.
    Self = self(),
    Cb1 = fun(_) -> Self ! {fired, 1}, ok end,
    Cb2 = fun(_) -> Self ! {fired, 2}, ok end,
    H1 = agent_wire_hooks:hook(stop, Cb1),
    H2 = agent_wire_hooks:hook(stop, Cb2),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    ?assertEqual(2, length(maps:get(stop, Reg))),
    %% Fire and verify execution order matches registration order
    ok = agent_wire_hooks:fire(stop, #{event => stop}, Reg),
    ?assertEqual({fired, 1}, receive M1 -> M1 after 100 -> timeout end),
    ?assertEqual({fired, 2}, receive M2 -> M2 after 100 -> timeout end).

%%====================================================================
%% Dispatch — Notification-only Events
%%====================================================================

fire_empty_registry_returns_ok_test() ->
    ?assertEqual(ok, agent_wire_hooks:fire(
        stop, #{event => stop}, agent_wire_hooks:new_registry())).

fire_undefined_registry_returns_ok_test() ->
    ?assertEqual(ok, agent_wire_hooks:fire(
        stop, #{event => stop}, undefined)).

fire_calls_callback_with_context_test() ->
    Self = self(),
    Ref = make_ref(),
    Cb = fun(Ctx) -> Self ! {Ref, Ctx}, ok end,
    H = agent_wire_hooks:hook(stop, Cb),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    Ctx = #{event => stop, session_id => <<"sess-1">>},
    ?assertEqual(ok, agent_wire_hooks:fire(stop, Ctx, Reg)),
    receive
        {Ref, ReceivedCtx} ->
            ?assertEqual(<<"sess-1">>, maps:get(session_id, ReceivedCtx))
    after 1000 ->
        ?assert(false)
    end.

fire_post_tool_use_ignores_deny_test() ->
    H = agent_wire_hooks:hook(post_tool_use,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual(ok, agent_wire_hooks:fire(
        post_tool_use, #{event => post_tool_use}, Reg)).

fire_stop_ignores_deny_test() ->
    H = agent_wire_hooks:hook(stop,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual(ok, agent_wire_hooks:fire(
        stop, #{event => stop}, Reg)).

fire_session_start_ignores_deny_test() ->
    H = agent_wire_hooks:hook(session_start,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual(ok, agent_wire_hooks:fire(
        session_start, #{event => session_start}, Reg)).

fire_session_end_ignores_deny_test() ->
    H = agent_wire_hooks:hook(session_end,
        fun(_) -> {deny, <<"nope">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual(ok, agent_wire_hooks:fire(
        session_end, #{event => session_end}, Reg)).

%%====================================================================
%% Dispatch — Blocking Events
%%====================================================================

fire_pre_tool_use_returns_deny_test() ->
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> {deny, <<"blocked">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual({deny, <<"blocked">>},
        agent_wire_hooks:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"Bash">>}, Reg)).

fire_user_prompt_submit_returns_deny_test() ->
    H = agent_wire_hooks:hook(user_prompt_submit,
        fun(_) -> {deny, <<"no prompts">>} end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    ?assertEqual({deny, <<"no prompts">>},
        agent_wire_hooks:fire(user_prompt_submit,
            #{event => user_prompt_submit, prompt => <<"hi">>}, Reg)).

fire_first_deny_wins_test() ->
    H1 = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> {deny, <<"first">>} end),
    H2 = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> {deny, <<"second">>} end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    ?assertEqual({deny, <<"first">>},
        agent_wire_hooks:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

fire_all_ok_returns_ok_test() ->
    H1 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    H2 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    ?assertEqual(ok,
        agent_wire_hooks:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

fire_ok_then_deny_returns_deny_test() ->
    H1 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    H2 = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> {deny, <<"blocked">>} end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    ?assertEqual({deny, <<"blocked">>},
        agent_wire_hooks:fire(pre_tool_use,
            #{event => pre_tool_use, tool_name => <<"X">>}, Reg)).

%%====================================================================
%% Matcher Tests
%%====================================================================

matcher_exact_match_fires_test() ->
    Self = self(),
    Ref = make_ref(),
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> Self ! {Ref, fired}, ok end,
        #{tool_name => <<"Bash">>}),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    agent_wire_hooks:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Bash">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

matcher_exact_match_skips_nonmatching_test() ->
    Self = self(),
    Ref = make_ref(),
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> Self ! {Ref, fired}, ok end,
        #{tool_name => <<"Bash">>}),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    agent_wire_hooks:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Read">>}, Reg),
    receive {Ref, fired} -> ?assert(false)
    after 100 -> ok
    end.

matcher_regex_pattern_matches_test() ->
    Self = self(),
    Ref = make_ref(),
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> Self ! {Ref, fired}, ok end,
        #{tool_name => <<"^Read.*">>}),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    agent_wire_hooks:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"ReadFile">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

matcher_regex_pattern_skips_nonmatching_test() ->
    Self = self(),
    Ref = make_ref(),
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> Self ! {Ref, fired}, ok end,
        #{tool_name => <<"^Read.*">>}),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    agent_wire_hooks:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"Write">>}, Reg),
    receive {Ref, fired} -> ?assert(false)
    after 100 -> ok
    end.

no_matcher_fires_on_all_tools_test() ->
    Self = self(),
    Ref = make_ref(),
    H = agent_wire_hooks:hook(pre_tool_use,
        fun(_) -> Self ! {Ref, fired}, ok end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    agent_wire_hooks:fire(pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"AnyTool">>}, Reg),
    receive {Ref, fired} -> ok
    after 500 -> ?assert(false)
    end.

%%====================================================================
%% Crash Protection Tests
%%====================================================================

callback_crash_is_caught_test() ->
    H1 = agent_wire_hooks:hook(stop, fun(_) -> error(boom) end),
    Self = self(),
    Ref = make_ref(),
    H2 = agent_wire_hooks:hook(stop,
        fun(_) -> Self ! {Ref, survived}, ok end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertEqual(ok, agent_wire_hooks:fire(
        stop, #{event => stop}, Reg)),
    logger:set_primary_config(level, OldLevel),
    receive {Ref, survived} -> ok
    after 500 -> ?assert(false)
    end.

callback_throw_is_caught_test() ->
    H = agent_wire_hooks:hook(stop, fun(_) -> throw(oops) end),
    Reg = agent_wire_hooks:register_hook(H, agent_wire_hooks:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertEqual(ok, agent_wire_hooks:fire(
        stop, #{event => stop}, Reg)),
    logger:set_primary_config(level, OldLevel).

blocking_callback_crash_returns_ok_test() ->
    %% A crashing callback in a blocking event should NOT deny —
    %% it returns ok and continues to next hook.
    H1 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> error(crash) end),
    H2 = agent_wire_hooks:hook(pre_tool_use, fun(_) -> ok end),
    Reg = agent_wire_hooks:register_hooks(
        [H1, H2], agent_wire_hooks:new_registry()),
    %% Suppress expected warning from safe_call crash handler
    #{level := OldLevel} = logger:get_primary_config(),
    logger:set_primary_config(level, none),
    ?assertEqual(ok, agent_wire_hooks:fire(
        pre_tool_use,
        #{event => pre_tool_use, tool_name => <<"X">>}, Reg)),
    logger:set_primary_config(level, OldLevel).
