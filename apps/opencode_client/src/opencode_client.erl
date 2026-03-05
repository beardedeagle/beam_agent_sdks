%%%-------------------------------------------------------------------
%%% @doc Convenience API facade for the OpenCode HTTP agent SDK.
%%%
%%% Thin wrapper over opencode_session providing high-level functions
%%% for common use cases. Richer than port-based adapters because
%%% OpenCode exposes full HTTP REST capabilities.
%%%
%%% For fine-grained control, use opencode_session directly.
%%% Mirrors codex_app_server.erl patterns for API consistency.
%%% @end
%%%-------------------------------------------------------------------
-module(opencode_client).

-export([
    %% Session lifecycle
    start_session/1,
    stop/1,
    child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Active query control
    abort/1,
    %% Session info & runtime control
    session_info/1,
    set_model/2,
    health/1,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3,
    %% OpenCode-specific REST operations
    list_sessions/1,
    get_session/2,
    delete_session/2,
    send_command/3,
    server_health/1
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start an OpenCode HTTP session.
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    opencode_session:start_link(Opts).

%% @doc Stop an OpenCode session.
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for an opencode_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> opencode_session;
        SId when is_binary(SId) -> {opencode_session, SId};
        SId -> {opencode_session, SId}
    end,
    #{
        id       => Id,
        start    => {opencode_session, start_link, [Opts]},
        restart  => transient,
        shutdown => 10000,
        type     => worker,
        modules  => [opencode_session]
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
    case gen_statem:call(Session, {send_query, Prompt, Params}, Timeout) of
        {ok, Ref} ->
            ReceiveFun = fun(S, R, T) ->
                gen_statem:call(S, {receive_message, R}, T)
            end,
            agent_wire:collect_messages(Session, Ref, Deadline, ReceiveFun);
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Active Query Control
%%====================================================================

%% @doc Abort the current active query.
-spec abort(pid()) -> ok | {error, term()}.
abort(Session) ->
    gen_statem:call(Session, abort, 10000).

%%====================================================================
%% Session Info & Runtime Control
%%====================================================================

%% @doc Query session info (session id, directory, model, transport).
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).

%% @doc Change the model at runtime.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).

%% @doc Query session health state.
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
%% OpenCode-specific REST Operations
%%====================================================================

%% @doc List all active sessions on the OpenCode server.
-spec list_sessions(pid()) -> {ok, [map()]} | {error, term()}.
list_sessions(Session) ->
    gen_statem:call(Session, list_sessions, 10000).

%% @doc Get details for a specific session by ID.
-spec get_session(pid(), binary()) -> {ok, map()} | {error, term()}.
get_session(Session, Id) ->
    gen_statem:call(Session, {get_session, Id}, 10000).

%% @doc Delete a session by ID.
-spec delete_session(pid(), binary()) -> {ok, term()} | {error, term()}.
delete_session(Session, Id) ->
    gen_statem:call(Session, {delete_session, Id}, 10000).

%% @doc Send a command to the current session.
-spec send_command(pid(), binary(), map()) -> {ok, term()} | {error, term()}.
send_command(Session, Command, Params) ->
    gen_statem:call(Session, {send_command, Command, Params}, 30000).

%% @doc Check the health of the OpenCode server.
-spec server_health(pid()) -> {ok, map()} | {error, term()}.
server_health(Session) ->
    gen_statem:call(Session, server_health, 5000).

%%====================================================================
%% Internal
%%====================================================================

%% @doc Collect messages until result/error/complete using deadline-based timeout.
