%%%-------------------------------------------------------------------
%%% @doc Convenience API for the Copilot CLI agent SDK.
%%%
%%% Thin wrapper over copilot_session providing high-level functions
%%% for common use cases. For fine-grained control, use
%%% copilot_session directly.
%%%
%%% Mirrors codex_app_server.erl / claude_agent_sdk.erl patterns
%%% for API consistency across all BEAM agent SDK adapters.
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_client).

-export([
    %% Session lifecycle
    start_session/1,
    stop/1,
    child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Session info
    session_info/1,
    %% Runtime control
    set_model/2,
    interrupt/1,
    abort/1,
    %% Health
    health/1,
    %% Arbitrary control
    send_command/3,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start a Copilot session (full bidirectional JSON-RPC via stdio).
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    copilot_session:start_link(Opts).

%% @doc Stop a session.
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for a copilot_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> copilot_session;
        SId when is_binary(SId) -> {copilot_session, SId};
        SId -> {copilot_session, SId}
    end,
    #{
        id => Id,
        start => {copilot_session, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [copilot_session]
    }.

%%====================================================================
%% Blocking Query
%%====================================================================

%% @doc Send a query and collect all response messages (blocking).
-spec query(pid(), binary()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

%% @doc Send a query with params and collect all response messages.
%%      Blocks until session.idle event or timeout.
-spec query(pid(), binary(), map()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            collect_messages(Session, Ref, Deadline, []);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Session Info
%%====================================================================

%% @doc Get session info (adapter, session_id, model, etc.).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    copilot_session:session_info(Session).

%%====================================================================
%% Runtime Control
%%====================================================================

%% @doc Change the model for this session.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    copilot_session:set_model(Session, Model).

%% @doc Abort the current query. Alias for interrupt/1.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    copilot_session:interrupt(Session).

%% @doc Abort the current query.
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    interrupt(Session).

%%====================================================================
%% Health
%%====================================================================

%% @doc Get the current health state.
-spec health(pid()) -> atom().
health(Session) ->
    copilot_session:health(Session).

%%====================================================================
%% Arbitrary Control
%%====================================================================

%% @doc Send an arbitrary JSON-RPC command to the Copilot CLI.
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Method, Params) ->
    copilot_session:send_control(Session, Method, Params).

%%====================================================================
%% SDK Hook Constructors
%%====================================================================

%% @doc Create an SDK hook definition (without matcher).
-spec sdk_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_callback()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback) ->
    agent_wire_hooks:hook(Event, Callback).

%% @doc Create an SDK hook definition (with matcher).
-spec sdk_hook(agent_wire_hooks:hook_event(), agent_wire_hooks:hook_callback(),
               agent_wire_hooks:hook_matcher()) -> agent_wire_hooks:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    agent_wire_hooks:hook(Event, Callback, Matcher).

%%====================================================================
%% Internal
%%====================================================================

%% @private Send a query through the behaviour API.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    copilot_session:send_query(Session, Prompt, Params, Timeout).

%% @private Collect messages until result/error using deadline-based timeout.
-spec collect_messages(pid(), reference(), timeout(), [agent_wire:message()]) ->
    {ok, [agent_wire:message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, Acc) ->
    collect_loop(Session, Ref, Deadline, Acc).

-spec collect_loop(pid(), reference(), integer(), [agent_wire:message()]) ->
    {ok, [agent_wire:message()]} | {error, term()}.
collect_loop(Session, Ref, Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Remaining = max(0, Deadline - Now),
    case receive_message_from(Session, Ref, Remaining) of
        {ok, #{type := result} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, #{type := error, is_error := true} = Msg} ->
            {ok, lists:reverse([Msg | Acc])};
        {ok, Msg} ->
            collect_loop(Session, Ref, Deadline, [Msg | Acc]);
        {error, timeout} ->
            {error, {timeout, lists:reverse(Acc)}};
        {error, _} = Err ->
            Err
    end.

%% @private Pull the next message from the session.
-spec receive_message_from(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    copilot_session:receive_message(Session, Ref, Timeout).
