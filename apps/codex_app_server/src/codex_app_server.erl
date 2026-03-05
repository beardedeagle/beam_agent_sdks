%%%-------------------------------------------------------------------
%%% @doc Convenience API for the Codex CLI agent SDK.
%%%
%%% Thin wrapper over codex_session and codex_exec providing high-level
%%% functions for common use cases. For fine-grained control, use
%%% codex_session or codex_exec directly.
%%%
%%% Mirrors claude_agent_sdk.erl patterns for API consistency.
%%% @end
%%%-------------------------------------------------------------------
-module(codex_app_server).

-export([
    %% Session lifecycle
    start_session/1,
    start_exec/1,
    stop/1,
    child_spec/1,
    exec_child_spec/1,
    %% Blocking query
    query/2,
    query/3,
    %% Thread management (app-server only)
    thread_start/2,
    thread_resume/2,
    thread_list/1,
    %% Session info
    session_info/1,
    %% Runtime control
    set_model/2,
    interrupt/1,
    %% Health
    health/1,
    %% SDK hook constructors
    sdk_hook/2,
    sdk_hook/3
]).

%%====================================================================
%% Session Lifecycle
%%====================================================================

%% @doc Start a Codex app-server session (full bidirectional JSON-RPC).
-spec start_session(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_session(Opts) ->
    codex_session:start_link(Opts).

%% @doc Start a Codex exec session (one-shot JSONL queries).
-spec start_exec(agent_wire:session_opts()) -> {ok, pid()} | {error, term()}.
start_exec(Opts) ->
    codex_exec:start_link(Opts).

%% @doc Stop a session (either app-server or exec).
-spec stop(pid()) -> ok.
stop(Session) ->
    gen_statem:stop(Session, normal, 10000).

%% @doc Supervisor child specification for a codex_session process.
-spec child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> codex_session;
        SId when is_binary(SId) -> {codex_session, SId};
        SId -> {codex_session, SId}
    end,
    #{
        id => Id,
        start => {codex_session, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [codex_session]
    }.

%% @doc Supervisor child specification for a codex_exec process.
-spec exec_child_spec(agent_wire:session_opts()) -> supervisor:child_spec().
exec_child_spec(Opts) ->
    Id = case maps:get(session_id, Opts, undefined) of
        undefined -> codex_exec;
        SId when is_binary(SId) -> {codex_exec, SId};
        SId -> {codex_exec, SId}
    end,
    #{
        id => Id,
        start => {codex_exec, start_link, [Opts]},
        restart => transient,
        shutdown => 10000,
        type => worker,
        modules => [codex_exec]
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
%% Thread Management (app-server only; exec returns {error, not_supported})
%%====================================================================

%% @doc Start a new conversation thread.
%%      Routes through gen_statem:call so both transports are supported.
%%      Returns `{error, not_supported}' for exec sessions.
-spec thread_start(pid(), map()) -> {ok, map()} | {error, term()}.
thread_start(Session, Opts) ->
    send_control_to(Session, <<"thread/start">>,
        codex_protocol:thread_start_params(Opts)).

%% @doc Resume an existing thread by ID.
-spec thread_resume(pid(), binary()) -> {ok, map()} | {error, term()}.
thread_resume(Session, ThreadId) ->
    send_control_to(Session, <<"thread/resume">>,
        #{<<"threadId">> => ThreadId}).

%% @doc List all threads.
-spec thread_list(pid()) -> {ok, [map()]} | {error, term()}.
thread_list(Session) ->
    send_control_to(Session, <<"thread/list">>, #{}).

%%====================================================================
%% Session Info & Runtime Control
%%====================================================================

%% @doc Query session info.  Works with both app-server and exec sessions.
-spec session_info(pid()) -> {ok, map()} | {error, term()}.
session_info(Session) ->
    gen_statem:call(Session, session_info, 5000).

%% @doc Change the model at runtime.  Works with both transports.
-spec set_model(pid(), binary()) -> {ok, term()} | {error, term()}.
set_model(Session, Model) ->
    gen_statem:call(Session, {set_model, Model}, 5000).

%% @doc Interrupt the current turn/query.  Works with both transports.
-spec interrupt(pid()) -> ok | {error, term()}.
interrupt(Session) ->
    gen_statem:call(Session, interrupt, 5000).

%%====================================================================
%% Health
%%====================================================================

%% @doc Query session health state.  Works with both app-server and exec sessions.
-spec health(pid()) -> ready | connecting | initializing | active_turn | active_query | error.
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

%% @doc Route query to the appropriate session module.
%%      Works with both codex_session and codex_exec via gen_statem:call.
-spec send_query_to(pid(), binary(), map(), timeout()) ->
    {ok, reference()} | {error, term()}.
send_query_to(Session, Prompt, Params, Timeout) ->
    gen_statem:call(Session, {send_query, Prompt, Params}, Timeout).

%% @doc Route control message to the session.
%%      codex_session processes the request; codex_exec returns {error, not_supported}.
-spec send_control_to(pid(), binary(), map()) ->
    {ok, term()} | {error, term()}.
send_control_to(Session, Method, Params) ->
    gen_statem:call(Session, {send_control, Method, Params}, 30000).

%% @doc Collect messages until result/error/complete using deadline-based timeout.

-spec receive_message_from(pid(), reference(), timeout()) ->
    {ok, agent_wire:message()} | {error, term()}.
receive_message_from(Session, Ref, Timeout) ->
    gen_statem:call(Session, {receive_message, Ref}, Timeout).
