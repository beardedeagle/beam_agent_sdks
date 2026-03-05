%%%-------------------------------------------------------------------
%%% @doc Convenience API for the Gemini CLI agent SDK.
%%%
%%% Thin wrapper over gemini_cli_session providing high-level
%%% functions for common use cases. For fine-grained control, use
%%% gemini_cli_session directly.
%%%
%%% Mirrors codex_app_server.erl patterns for API consistency.
%%% @end
%%%-------------------------------------------------------------------
-module(gemini_cli_client).

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
    health/1,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start a Gemini CLI session (one-shot JSONL queries).
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    gemini_cli_session:start_link(Opts).

%% @doc Stop a session.
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for a gemini_cli_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> gemini_cli_session;
        SId when is_binary(SId) -> {gemini_cli_session, SId};
        SId -> {gemini_cli_session, SId}
    end,
    #{
        id       => Id,
        start    => {gemini_cli_session, start_link, [Opts]},
        restart  => transient,
        shutdown => 10000,
        type     => worker,
        modules  => [gemini_cli_session]
    }.

%%====================================================================
%% Blocking Query
%%====================================================================

%% @doc Send a query and collect all response messages (blocking).
-spec query(pid(), binary()) -> {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt) ->
    query(Session, Prompt, #{}).

%% @doc Send a query with parameters, collect all messages (blocking).
%%      Uses deadline-based timeout.
-spec query(pid(), binary(), agent_wire:query_opts()) ->
    {ok, [agent_wire:message()]} | {error, term()}.
query(Session, Prompt, Params) ->
    Timeout = maps:get(timeout, Params, 120000),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    case send_query_to(Session, Prompt, Params, Timeout) of
        {ok, Ref} ->
            agent_wire:collect_messages(Session, Ref, Deadline,
                fun receive_message_from/3);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Session Info & Runtime Control
%%====================================================================

%% @doc Query session info.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).

%% @doc Change the model at runtime.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).

%% @doc Interrupt the current query.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).

%% @doc Query session health.
-spec health(pid()) -> ready | connecting | initializing | active_query | error.
health(Session) ->
    gen_statem:call(Session, health, 5000).

%%====================================================================
%% SDK Hook Constructors
%%====================================================================

%% @doc Create an SDK lifecycle hook.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback) ->
    agent_wire_hooks:hook(Event, Callback).

%% @doc Create an SDK lifecycle hook with a matcher.
-spec sdk_hook(agent_wire_hooks:hook_event(),
               agent_wire_hooks:hook_callback(),
               agent_wire_hooks:hook_matcher()) ->
    agent_wire_hooks:hook_def().
sdk_hook(Event, Callback, Matcher) ->
    agent_wire_hooks:hook(Event, Callback, Matcher).

%%====================================================================
%% Internal
%%====================================================================

%% @doc Route query to the session via gen_statem:call.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    gen_statem:call(Session, {send_query, Prompt, Params}, Timeout).

%% @doc Collect messages until result/error/complete using deadline-based timeout.

-spec receive_message_from(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).
