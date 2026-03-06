%%%-------------------------------------------------------------------
%%% @doc Universal session history store for the BEAM Agent SDK.
%%%
%%% Provides session tracking and message history across all adapters.
%%% This is agent_wire's own implementation — every adapter records
%%% messages here, regardless of whether the underlying CLI has native
%%% session history support.
%%%
%%% Uses ETS for fast in-process storage. Sessions persist for the
%%% lifetime of the BEAM node (or until explicitly deleted/cleared).
%%%
%%% Two ETS tables:
%%%   - `agent_wire_sessions` — session metadata (id, model, cwd, etc.)
%%%   - `agent_wire_session_messages` — messages keyed by {session_id, seq}
%%%
%%% Tables are created lazily on first access and are public/named so
%%% any process can read/write without bottlenecking on a single owner.
%%%
%%% Usage:
%%% ```
%%% %% Record messages as they arrive:
%%% agent_wire_session_store:record_message(SessionId, Message),
%%%
%%% %% Query history:
%%% {ok, Sessions} = agent_wire_session_store:list_sessions(),
%%% {ok, Messages} = agent_wire_session_store:get_session_messages(SessionId)
%%% ```
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_session_store).

-export([
    %% Table lifecycle
    ensure_tables/0,
    clear/0,
    %% Session metadata
    register_session/2,
    update_session/2,
    get_session/1,
    delete_session/1,
    list_sessions/0,
    list_sessions/1,
    %% Message storage
    record_message/2,
    record_messages/2,
    get_session_messages/1,
    get_session_messages/2,
    %% Convenience
    session_count/0,
    message_count/1
]).

-export_type([session_meta/0, list_opts/0, message_opts/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Session metadata stored in the sessions table.
-type session_meta() :: #{
    session_id := binary(),
    adapter => atom(),
    model => binary(),
    cwd => binary(),
    created_at => integer(),
    updated_at => integer(),
    message_count => non_neg_integer(),
    extra => map()
}.

%% Options for list_sessions/1.
-type list_opts() :: #{
    adapter => atom(),
    cwd => binary(),
    model => binary(),
    limit => pos_integer(),
    since => integer()
}.

%% Options for get_session_messages/2.
-type message_opts() :: #{
    limit => pos_integer(),
    offset => non_neg_integer(),
    types => [agent_wire:message_type()]
}.

%% ETS table names.
-define(SESSIONS_TABLE, agent_wire_sessions).
-define(MESSAGES_TABLE, agent_wire_session_messages).
%% Counter table for message sequence numbers per session.
-define(COUNTERS_TABLE, agent_wire_session_counters).

%%--------------------------------------------------------------------
%% Table Lifecycle
%%--------------------------------------------------------------------

%% @doc Ensure ETS tables exist. Idempotent — safe to call multiple times.
%%      Tables are public and named so any process can access them.
-spec ensure_tables() -> ok.
ensure_tables() ->
    ensure_table(?SESSIONS_TABLE, [set, public, named_table,
        {read_concurrency, true}]),
    ensure_table(?MESSAGES_TABLE, [ordered_set, public, named_table,
        {read_concurrency, true}]),
    ensure_table(?COUNTERS_TABLE, [set, public, named_table]),
    ok.

%% @doc Clear all session data. Deletes all entries from both tables.
-spec clear() -> ok.
clear() ->
    ensure_tables(),
    ets:delete_all_objects(?SESSIONS_TABLE),
    ets:delete_all_objects(?MESSAGES_TABLE),
    ets:delete_all_objects(?COUNTERS_TABLE),
    ok.

%%--------------------------------------------------------------------
%% Session Metadata
%%--------------------------------------------------------------------

%% @doc Register a new session with metadata.
%%      If the session already exists, this is a no-op (use update_session
%%      to modify existing sessions).
-spec register_session(binary(), map()) -> ok.
register_session(SessionId, Meta) when is_binary(SessionId), is_map(Meta) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    Entry = Meta#{
        session_id => SessionId,
        created_at => maps:get(created_at, Meta, Now),
        updated_at => Now,
        message_count => 0
    },
    %% insert_new: only insert if not already present
    ets:insert_new(?SESSIONS_TABLE, {SessionId, Entry}),
    ok.

%% @doc Update an existing session's metadata.
%%      Merges the provided fields into the existing metadata.
%%      Creates the session if it doesn't exist.
-spec update_session(binary(), map()) -> ok.
update_session(SessionId, Updates) when is_binary(SessionId), is_map(Updates) ->
    ensure_tables(),
    Now = erlang:system_time(millisecond),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Existing}] ->
            Updated = maps:merge(Existing, Updates#{updated_at => Now}),
            ets:insert(?SESSIONS_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            register_session(SessionId, Updates)
    end.

%% @doc Get metadata for a specific session.
-spec get_session(binary()) -> {ok, session_meta()} | {error, not_found}.
get_session(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Meta}] -> {ok, Meta};
        [] -> {error, not_found}
    end.

%% @doc Delete a session and all its messages.
-spec delete_session(binary()) -> ok.
delete_session(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    ets:delete(?SESSIONS_TABLE, SessionId),
    ets:delete(?COUNTERS_TABLE, SessionId),
    %% Delete all messages for this session.
    %% Messages are keyed as {SessionId, Seq} in an ordered_set,
    %% so we can efficiently match on the prefix.
    delete_session_messages(SessionId),
    ok.

%% @doc List all sessions. Equivalent to list_sessions(#{}).
-spec list_sessions() -> {ok, [session_meta()]}.
list_sessions() ->
    list_sessions(#{}).

%% @doc List sessions with optional filters.
%%      Filters: adapter, cwd, model, limit, since (unix ms timestamp).
%%      Results are sorted by updated_at descending.
-spec list_sessions(list_opts()) -> {ok, [session_meta()]}.
list_sessions(Opts) when is_map(Opts) ->
    ensure_tables(),
    All = ets:foldl(fun({_, Meta}, Acc) ->
        case matches_filters(Meta, Opts) of
            true -> [Meta | Acc];
            false -> Acc
        end
    end, [], ?SESSIONS_TABLE),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(updated_at, A, 0) >= maps:get(updated_at, B, 0)
    end, All),
    Limited = case maps:get(limit, Opts, infinity) of
        infinity -> Sorted;
        N when is_integer(N), N > 0 -> lists:sublist(Sorted, N)
    end,
    {ok, Limited}.

%%--------------------------------------------------------------------
%% Message Storage
%%--------------------------------------------------------------------

%% @doc Record a single message for a session.
%%      The message is stored with an auto-incrementing sequence number
%%      for ordering.  Session metadata is auto-created if not present.
-spec record_message(binary(), agent_wire:message()) -> ok.
record_message(SessionId, Message) when is_binary(SessionId), is_map(Message) ->
    ensure_tables(),
    Seq = ets:update_counter(?COUNTERS_TABLE, SessionId, {2, 1},
        {SessionId, 0}),
    ets:insert(?MESSAGES_TABLE, {{SessionId, Seq}, Message}),
    %% Update session metadata
    update_message_count(SessionId, Message),
    ok.

%% @doc Record multiple messages for a session.
-spec record_messages(binary(), [agent_wire:message()]) -> ok.
record_messages(SessionId, Messages)
  when is_binary(SessionId), is_list(Messages) ->
    lists:foreach(fun(Msg) ->
        record_message(SessionId, Msg)
    end, Messages),
    ok.

%% @doc Get all messages for a session, in order.
%%      Equivalent to get_session_messages(SessionId, #{}).
-spec get_session_messages(binary()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId) ->
    get_session_messages(SessionId, #{}).

%% @doc Get messages for a session with options.
%%      Options:
%%        - limit: maximum number of messages
%%        - offset: skip this many messages from the start
%%        - types: only include messages of these types
-spec get_session_messages(binary(), message_opts()) ->
    {ok, [agent_wire:message()]} | {error, not_found}.
get_session_messages(SessionId, Opts)
  when is_binary(SessionId), is_map(Opts) ->
    ensure_tables(),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [] ->
            {error, not_found};
        _ ->
            Messages = collect_session_messages(SessionId),
            Filtered = apply_message_filters(Messages, Opts),
            {ok, Filtered}
    end.

%%--------------------------------------------------------------------
%% Convenience
%%--------------------------------------------------------------------

%% @doc Get the total number of tracked sessions.
-spec session_count() -> non_neg_integer().
session_count() ->
    ensure_tables(),
    ets:info(?SESSIONS_TABLE, size).

%% @doc Get the message count for a specific session.
-spec message_count(binary()) -> non_neg_integer().
message_count(SessionId) when is_binary(SessionId) ->
    ensure_tables(),
    case ets:lookup(?COUNTERS_TABLE, SessionId) of
        [{_, Count}] -> Count;
        [] -> 0
    end.

%%--------------------------------------------------------------------
%% Internal: ETS Table Management
%%--------------------------------------------------------------------

-spec ensure_table(atom(), [term()]) -> ok.
ensure_table(Name, Opts) ->
    case ets:whereis(Name) of
        undefined ->
            try
                _ = ets:new(Name, Opts),
                ok
            catch
                error:badarg ->
                    %% Race condition: another process created it first
                    ok
            end;
        _Tid ->
            ok
    end.

%%--------------------------------------------------------------------
%% Internal: Filter Matching
%%--------------------------------------------------------------------

-spec matches_filters(session_meta(), list_opts()) -> boolean().
matches_filters(Meta, Opts) ->
    match_field(adapter, Meta, Opts) andalso
    match_field(cwd, Meta, Opts) andalso
    match_field(model, Meta, Opts) andalso
    match_since(Meta, Opts).

-spec match_field(atom(), session_meta(), list_opts()) -> boolean().
match_field(Key, Meta, Opts) ->
    case maps:find(Key, Opts) of
        {ok, Expected} ->
            maps:get(Key, Meta, undefined) =:= Expected;
        error ->
            true
    end.

-spec match_since(session_meta(), list_opts()) -> boolean().
match_since(Meta, Opts) ->
    case maps:find(since, Opts) of
        {ok, Since} ->
            maps:get(updated_at, Meta, 0) >= Since;
        error ->
            true
    end.

%%--------------------------------------------------------------------
%% Internal: Message Collection
%%--------------------------------------------------------------------

-spec collect_session_messages(binary()) -> [agent_wire:message()].
collect_session_messages(SessionId) ->
    %% ordered_set with {SessionId, Seq} keys gives us sorted order
    %% for free within a session prefix.
    StartKey = {SessionId, 0},
    collect_from(StartKey, SessionId, []).

-spec collect_from(term(), binary(), [agent_wire:message()]) ->
    [agent_wire:message()].
collect_from(Key, SessionId, Acc) ->
    case ets:next(?MESSAGES_TABLE, Key) of
        '$end_of_table' ->
            lists:reverse(Acc);
        {SessionId, _Seq} = NextKey ->
            case ets:lookup(?MESSAGES_TABLE, NextKey) of
                [{_, Msg}] ->
                    collect_from(NextKey, SessionId, [Msg | Acc]);
                [] ->
                    collect_from(NextKey, SessionId, Acc)
            end;
        _OtherSession ->
            %% Moved past our session's prefix
            lists:reverse(Acc)
    end.

-spec apply_message_filters([agent_wire:message()], message_opts()) ->
    [agent_wire:message()].
apply_message_filters(Messages, Opts) ->
    M1 = case maps:find(types, Opts) of
        {ok, Types} when is_list(Types) ->
            [M || #{type := T} = M <- Messages, lists:member(T, Types)];
        _ ->
            Messages
    end,
    M2 = case maps:find(offset, Opts) of
        {ok, Offset} when is_integer(Offset), Offset > 0 ->
            lists:nthtail(min(Offset, length(M1)), M1);
        _ ->
            M1
    end,
    case maps:find(limit, Opts) of
        {ok, Limit} when is_integer(Limit), Limit > 0 ->
            lists:sublist(M2, Limit);
        _ ->
            M2
    end.

%%--------------------------------------------------------------------
%% Internal: Session Metadata Updates
%%--------------------------------------------------------------------

-spec update_message_count(binary(), agent_wire:message()) -> ok.
update_message_count(SessionId, Message) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?SESSIONS_TABLE, SessionId) of
        [{_, Existing}] ->
            Count = maps:get(message_count, Existing, 0) + 1,
            Updates = #{message_count => Count, updated_at => Now},
            %% Extract model from system init or result messages
            Updates2 = maybe_extract_model(Message, Updates),
            Updated = maps:merge(Existing, Updates2),
            ets:insert(?SESSIONS_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            %% Auto-create session entry if not registered
            Meta = maybe_extract_model(Message,
                #{message_count => 1, updated_at => Now}),
            register_session(SessionId, Meta)
    end.

-spec maybe_extract_model(agent_wire:message(), map()) -> map().
maybe_extract_model(#{type := system, system_info := #{model := Model}}, Acc)
  when is_binary(Model) ->
    Acc#{model => Model};
maybe_extract_model(#{model := Model}, Acc) when is_binary(Model) ->
    Acc#{model => Model};
maybe_extract_model(_, Acc) ->
    Acc.

%%--------------------------------------------------------------------
%% Internal: Message Deletion
%%--------------------------------------------------------------------

-spec delete_session_messages(binary()) -> ok.
delete_session_messages(SessionId) ->
    StartKey = {SessionId, 0},
    delete_from(StartKey, SessionId).

-spec delete_from(term(), binary()) -> ok.
delete_from(Key, SessionId) ->
    case ets:next(?MESSAGES_TABLE, Key) of
        '$end_of_table' ->
            ok;
        {SessionId, _Seq} = NextKey ->
            ets:delete(?MESSAGES_TABLE, NextKey),
            delete_from(Key, SessionId);
        _OtherSession ->
            ok
    end.
