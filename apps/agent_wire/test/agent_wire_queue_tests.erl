%%%-------------------------------------------------------------------
%%% @doc EUnit + PropEr tests for agent_wire_queue.
%%%
%%% Validates the bounded queue invariants:
%%%   - FIFO ordering is preserved
%%%   - Length tracking is accurate
%%%   - Bounded capacity is enforced
%%%   - push/pop are inverses for the data dimension
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%%====================================================================
%% EUnit: basic operations
%%====================================================================

new_unbounded_test() ->
    Q = agent_wire_queue:new(),
    ?assertEqual(0, agent_wire_queue:len(Q)),
    ?assert(agent_wire_queue:is_empty(Q)),
    ?assertNot(agent_wire_queue:is_full(Q)),
    ?assertEqual([], agent_wire_queue:to_list(Q)).

new_bounded_test() ->
    Q = agent_wire_queue:new(5),
    ?assertEqual(0, agent_wire_queue:len(Q)),
    ?assert(agent_wire_queue:is_empty(Q)),
    ?assertNot(agent_wire_queue:is_full(Q)).

push_pop_single_test() ->
    Q0 = agent_wire_queue:new(),
    {ok, Q1} = agent_wire_queue:push(hello, Q0),
    ?assertEqual(1, agent_wire_queue:len(Q1)),
    ?assertNot(agent_wire_queue:is_empty(Q1)),
    {ok, hello, Q2} = agent_wire_queue:pop(Q1),
    ?assertEqual(0, agent_wire_queue:len(Q2)),
    ?assert(agent_wire_queue:is_empty(Q2)).

push_pop_fifo_test() ->
    Q0 = agent_wire_queue:new(),
    {ok, Q1} = agent_wire_queue:push(a, Q0),
    {ok, Q2} = agent_wire_queue:push(b, Q1),
    {ok, Q3} = agent_wire_queue:push(c, Q2),
    ?assertEqual([a, b, c], agent_wire_queue:to_list(Q3)),
    {ok, a, Q4} = agent_wire_queue:pop(Q3),
    {ok, b, Q5} = agent_wire_queue:pop(Q4),
    {ok, c, Q6} = agent_wire_queue:pop(Q5),
    ?assertEqual(empty, agent_wire_queue:pop(Q6)).

pop_empty_test() ->
    Q = agent_wire_queue:new(),
    ?assertEqual(empty, agent_wire_queue:pop(Q)).

%%====================================================================
%% EUnit: bounded capacity
%%====================================================================

bounded_rejects_overflow_test() ->
    Q0 = agent_wire_queue:new(2),
    {ok, Q1} = agent_wire_queue:push(a, Q0),
    {ok, Q2} = agent_wire_queue:push(b, Q1),
    ?assert(agent_wire_queue:is_full(Q2)),
    ?assertEqual({error, queue_full}, agent_wire_queue:push(c, Q2)).

bounded_allows_after_pop_test() ->
    Q0 = agent_wire_queue:new(2),
    {ok, Q1} = agent_wire_queue:push(a, Q0),
    {ok, Q2} = agent_wire_queue:push(b, Q1),
    ?assert(agent_wire_queue:is_full(Q2)),
    {ok, a, Q3} = agent_wire_queue:pop(Q2),
    ?assertNot(agent_wire_queue:is_full(Q3)),
    {ok, Q4} = agent_wire_queue:push(c, Q3),
    ?assertEqual([b, c], agent_wire_queue:to_list(Q4)).

bounded_size_one_test() ->
    Q0 = agent_wire_queue:new(1),
    {ok, Q1} = agent_wire_queue:push(only, Q0),
    ?assert(agent_wire_queue:is_full(Q1)),
    ?assertEqual({error, queue_full}, agent_wire_queue:push(extra, Q1)),
    {ok, only, Q2} = agent_wire_queue:pop(Q1),
    ?assert(agent_wire_queue:is_empty(Q2)).

%%====================================================================
%% EUnit: unbounded never reports full
%%====================================================================

unbounded_never_full_test() ->
    Q0 = agent_wire_queue:new(),
    Q = lists:foldl(fun(I, Acc) ->
        {ok, Next} = agent_wire_queue:push(I, Acc),
        Next
    end, Q0, lists:seq(1, 1000)),
    ?assertEqual(1000, agent_wire_queue:len(Q)),
    ?assertNot(agent_wire_queue:is_full(Q)).

%%====================================================================
%% EUnit: to_list preserves FIFO order
%%====================================================================

to_list_order_test() ->
    Items = [a, b, c, d, e],
    Q = lists:foldl(fun(I, Acc) ->
        {ok, Next} = agent_wire_queue:push(I, Acc),
        Next
    end, agent_wire_queue:new(), Items),
    ?assertEqual(Items, agent_wire_queue:to_list(Q)).

%%====================================================================
%% PropEr: FIFO ordering invariant
%%====================================================================

prop_fifo_ordering() ->
    ?FORALL(Items, non_empty(list(term())),
    begin
        Q = lists:foldl(fun(I, Acc) ->
            {ok, Next} = agent_wire_queue:push(I, Acc),
            Next
        end, agent_wire_queue:new(), Items),

        %% Pop all items — must come out in insertion order
        Popped = pop_all(Q),
        ?assertEqual(Items, Popped),
        true
    end).

%% Helper: pop all items from queue
pop_all(Q) ->
    case agent_wire_queue:pop(Q) of
        empty -> [];
        {ok, Item, Q2} -> [Item | pop_all(Q2)]
    end.

%%====================================================================
%% PropEr: length tracking invariant
%%====================================================================

prop_length_tracking() ->
    ?FORALL(Items, list(term()),
    begin
        Q = lists:foldl(fun(I, Acc) ->
            {ok, Next} = agent_wire_queue:push(I, Acc),
            Next
        end, agent_wire_queue:new(), Items),

        ?assertEqual(length(Items), agent_wire_queue:len(Q)),

        %% Pop half, check length again
        HalfLen = length(Items) div 2,
        {Q2, _} = lists:foldl(fun(_, {QAcc, N}) when N >= HalfLen ->
            {QAcc, N};
        (_, {QAcc, N}) ->
            {ok, _, QNext} = agent_wire_queue:pop(QAcc),
            {QNext, N + 1}
        end, {Q, 0}, Items),

        ?assertEqual(length(Items) - HalfLen, agent_wire_queue:len(Q2)),
        true
    end).

%%====================================================================
%% PropEr: bounded capacity enforcement
%%====================================================================

prop_bounded_capacity() ->
    ?FORALL({Max, Items}, {range(1, 50), non_empty(list(term()))},
    begin
        Q0 = agent_wire_queue:new(Max),
        {FinalQ, Rejected} = lists:foldl(
            fun(Item, {QAcc, RejAcc}) ->
                case agent_wire_queue:push(Item, QAcc) of
                    {ok, QNext} -> {QNext, RejAcc};
                    {error, queue_full} -> {QAcc, RejAcc + 1}
                end
            end,
            {Q0, 0},
            Items
        ),

        Accepted = length(Items) - Rejected,
        ?assertEqual(Accepted, agent_wire_queue:len(FinalQ)),
        ?assert(agent_wire_queue:len(FinalQ) =< Max),
        true
    end).

%%====================================================================
%% PropEr: push/pop symmetry — what goes in comes out
%%====================================================================

prop_push_pop_symmetry() ->
    ?FORALL(Items, non_empty(list(integer())),
    begin
        Q = lists:foldl(fun(I, Acc) ->
            {ok, Next} = agent_wire_queue:push(I, Acc),
            Next
        end, agent_wire_queue:new(), Items),

        Popped = pop_all(Q),
        ?assertEqual(Items, Popped),
        true
    end).

%%====================================================================
%% PropEr runner (EUnit integration)
%%====================================================================

proper_test_() ->
    Opts = [{numtests, 200}, {to_file, user}],
    [
        {"FIFO ordering",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_fifo_ordering(), Opts)) end}},
        {"length tracking",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_length_tracking(), Opts)) end}},
        {"bounded capacity",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_bounded_capacity(), Opts)) end}},
        {"push/pop symmetry",
         {timeout, 30,
          fun() -> ?assert(proper:quickcheck(prop_push_pop_symmetry(), Opts)) end}}
    ].
