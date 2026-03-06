%%%-------------------------------------------------------------------
%%% @doc Universal thread/conversation management for the BEAM Agent SDK.
%%%
%%% Provides logical conversation threading across all adapters.
%%% A thread groups related queries into a named conversation context.
%%%
%%% Uses the same ETS-backed approach as agent_wire_session_store.
%%% Threads are scoped to a session — each session can have multiple
%%% threads, and each thread tracks its query history.
%%%
%%% Usage:
%%% ```
%%% %% Start a new thread:
%%% {ok, Thread} = agent_wire_threads:start_thread(SessionId, #{
%%%     name => <<"feature-discussion">>
%%% }),
%%%
%%% %% List threads:
%%% {ok, Threads} = agent_wire_threads:list_threads(SessionId),
%%%
%%% %% Resume a thread:
%%% {ok, Thread} = agent_wire_threads:resume_thread(SessionId, ThreadId)
%%% ```
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_threads).

-export([
    %% Table lifecycle
    ensure_table/0,
    clear/0,
    %% Thread operations
    start_thread/2,
    resume_thread/2,
    list_threads/1,
    get_thread/2,
    delete_thread/2,
    %% Thread message tracking
    record_thread_message/3,
    get_thread_messages/2,
    %% Convenience
    thread_count/1,
    active_thread/1,
    set_active_thread/2,
    clear_active_thread/1
]).

-export_type([thread_meta/0, thread_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Thread metadata.
-type thread_meta() :: #{
    thread_id := binary(),
    session_id := binary(),
    name => binary(),
    created_at := integer(),
    updated_at := integer(),
    message_count := non_neg_integer(),
    status := active | paused | completed
}.

%% Options for start_thread/2.
-type thread_opts() :: #{
    name => binary(),
    thread_id => binary()
}.

%% ETS table name.
-define(THREADS_TABLE, agent_wire_threads).
%% Active thread per session.
-define(ACTIVE_TABLE, agent_wire_active_threads).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

%% @doc Ensure the threads ETS table exists. Idempotent.
-spec ensure_table() -> ok.
ensure_table() ->
    ensure_ets(?THREADS_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_ets(?ACTIVE_TABLE, [set, public, named_table]),
    ok.

%% @doc Clear all thread data.
-spec clear() -> ok.
clear() ->
    ensure_table(),
    ets:delete_all_objects(?THREADS_TABLE),
    ets:delete_all_objects(?ACTIVE_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Thread Operations
%%--------------------------------------------------------------------

%% @doc Start a new conversation thread within a session.
%%      Generates a thread ID if not provided in opts.
%%      Returns the thread metadata.
-spec start_thread(binary(), thread_opts()) -> {ok, thread_meta()}.
start_thread(SessionId, Opts) when is_binary(SessionId), is_map(Opts) ->
    ensure_table(),
    ThreadId = maps:get(thread_id, Opts,
        generate_thread_id()),
    Now = erlang:system_time(millisecond),
    Thread = #{
        thread_id => ThreadId,
        session_id => SessionId,
        name => maps:get(name, Opts, ThreadId),
        created_at => Now,
        updated_at => Now,
        message_count => 0,
        status => active
    },
    Key = {SessionId, ThreadId},
    ets:insert(?THREADS_TABLE, {Key, Thread}),
    %% Set as active thread for this session
    set_active_thread(SessionId, ThreadId),
    {ok, Thread}.

%% @doc Resume an existing thread by ID.
%%      Sets it as the active thread for the session.
%%      Returns {error, not_found} if the thread doesn't exist.
-spec resume_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
resume_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] ->
            Now = erlang:system_time(millisecond),
            Updated = Thread#{
                status => active,
                updated_at => Now
            },
            ets:insert(?THREADS_TABLE, {Key, Updated}),
            set_active_thread(SessionId, ThreadId),
            {ok, Updated};
        [] ->
            {error, not_found}
    end.

%% @doc List all threads for a session, sorted by updated_at descending.
-spec list_threads(binary()) -> {ok, [thread_meta()]}.
list_threads(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    Threads = ets:foldl(fun
        ({{SId, _}, Thread}, Acc) when SId =:= SessionId ->
            [Thread | Acc];
        (_, Acc) ->
            Acc
    end, [], ?THREADS_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0)
    end, Threads),
    {ok, Sorted}.

%% @doc Get a specific thread by ID.
-spec get_thread(binary(), binary()) ->
    {ok, thread_meta()} | {error, not_found}.
get_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] -> {ok, Thread};
        [] -> {error, not_found}
    end.

%% @doc Delete a thread.
-spec delete_thread(binary(), binary()) -> ok.
delete_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    ets:delete(?THREADS_TABLE, Key),
    %% Clear active thread if this was it
    case active_thread(SessionId) of
        {ok, ThreadId} -> clear_active_thread(SessionId);
        _ -> ok
    end,
    ok.

%%--------------------------------------------------------------------
%% Thread Message Tracking
%%--------------------------------------------------------------------

%% @doc Record a message against a thread.
%%      Also records the message in the session store for unified history.
-spec record_thread_message(binary(), binary(), agent_wire:message()) -> ok.
record_thread_message(SessionId, ThreadId, Message)
  when is_binary(SessionId), is_binary(ThreadId), is_map(Message) ->
    ensure_table(),
    Key = {SessionId, ThreadId},
    case ets:lookup(?THREADS_TABLE, Key) of
        [{_, Thread}] ->
            Now = erlang:system_time(millisecond),
            Count = maps:get(message_count, Thread, 0) + 1,
            Updated = Thread#{
                message_count => Count,
                updated_at => Now
            },
            ets:insert(?THREADS_TABLE, {Key, Updated});
        [] ->
            ok
    end,
    %% Also record in the session-level message store
    TaggedMessage = Message#{thread_id => ThreadId},
    agent_wire_session_store:record_message(SessionId, TaggedMessage),
    ok.

%% @doc Get all messages for a specific thread.
%%      Filters session messages by thread_id tag.
-spec get_thread_messages(binary(), binary()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_thread_messages(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    case get_thread(SessionId, ThreadId) of
        {ok, _} ->
            case agent_wire_session_store:get_session_messages(SessionId) of
                {ok, AllMessages} ->
                    ThreadMessages = [M || #{thread_id := TId} = M
                        <- AllMessages, TId =:= ThreadId],
                    {ok, ThreadMessages};
                {error, not_found} ->
                    {ok, []}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

%% @doc Count threads for a session.
-spec thread_count(binary()) -> non_neg_integer().
thread_count(SessionId) when is_binary(SessionId) ->
    {ok, Threads} = list_threads(SessionId),
    length(Threads).

%% @doc Get the currently active thread for a session.
-spec active_thread(binary()) -> {ok, binary()} | {error, none}.
active_thread(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    case ets:lookup(?ACTIVE_TABLE, SessionId) of
        [{_, ThreadId}] -> {ok, ThreadId};
        [] -> {error, none}
    end.

%% @doc Set the active thread for a session.
-spec set_active_thread(binary(), binary()) -> ok.
set_active_thread(SessionId, ThreadId)
  when is_binary(SessionId), is_binary(ThreadId) ->
    ensure_table(),
    ets:insert(?ACTIVE_TABLE, {SessionId, ThreadId}),
    ok.

%% @doc Clear the active thread for a session.
-spec clear_active_thread(binary()) -> ok.
clear_active_thread(SessionId) when is_binary(SessionId) ->
    ensure_table(),
    ets:delete(?ACTIVE_TABLE, SessionId),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec generate_thread_id() -> binary().
generate_thread_id() ->
    Hex = binary:encode_hex(rand:bytes(8), lowercase),
    <<"thread_", Hex/binary>>.

-spec ensure_ets(atom(), [term()]) -> ok.
ensure_ets(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg -> ok
            end;
        _Tid ->
            ok
    end.
