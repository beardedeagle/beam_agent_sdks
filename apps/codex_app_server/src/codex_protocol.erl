%%%-------------------------------------------------------------------
%%% @doc Codex message normalization and wire format builders.
%%%
%%% Maps Codex-specific JSON-RPC notifications/responses to/from
%%% agent_wire:message() and builds wire-format params for Codex
%%% JSON-RPC methods.
%%%
%%% Codex uses camelCase field names and a thread/turn model.
%%% Notifications arrive as JSON-RPC notifications (method + params).
%%% @end
%%%-------------------------------------------------------------------
-module(codex_protocol).

-export([
    %% Notification normalization
    normalize_notification/2,
    %% Wire param builders
    thread_start_params/1,
    turn_start_params/2,
    turn_start_params/3,
    initialize_params/1,
    %% Approval response building
    command_approval_response/1,
    file_approval_response/1,
    %% Text input helper
    text_input/1,
    %% Enum parsing/encoding
    parse_approval_decision/1,
    encode_approval_decision/1,
    encode_ask_for_approval/1,
    encode_sandbox_mode/1
]).

-export_type([
    approval_decision/0,
    file_approval_decision/0,
    ask_for_approval/0,
    sandbox_mode/0,
    user_input/0
]).

%% Normalization covers many Codex notification methods — the catch-all
%% clause is intentionally broad to preserve unknown notifications as raw.
-dialyzer({nowarn_function, [normalize_notification/2]}).
-dialyzer({no_underspecs, [
    thread_start_params/1,
    turn_start_params/2,
    turn_start_params/3,
    initialize_params/1,
    command_approval_response/1,
    file_approval_response/1,
    text_input/1,
    encode_approval_decision/1,
    encode_ask_for_approval/1,
    encode_sandbox_mode/1,
    maybe_put/3,
    maybe_put_opt/4
]}).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type approval_decision() :: accept | accept_for_session | decline | cancel.
-type file_approval_decision() :: accept | accept_for_session | decline | cancel.
-type ask_for_approval() :: untrusted | on_failure | on_request | reject | never.
-type sandbox_mode() :: read_only | workspace_write | danger_full_access.

-type user_input() :: #{type := binary(), text => binary(), _ => _}.

%%====================================================================
%% Notification Normalization
%%====================================================================

%% @doc Normalize a Codex JSON-RPC notification into agent_wire:message().
%%      Method is the notification method, Params is the params map.
-spec normalize_notification(binary(), map()) -> agent_wire:message().

%% Streaming text content delta
normalize_notification(<<"item/agentMessage/delta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => text,
      content => Delta,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% Item started — depends on item type
normalize_notification(<<"item/started">>, #{<<"item">> := Item} = Params) ->
    normalize_item_started(maps:get(<<"type">>, Item, <<>>), Item, Params);
normalize_notification(<<"item/started">>, Params) ->
    #{type => raw, raw => Params,
      timestamp => erlang:system_time(millisecond)};

%% Item completed — depends on item type
normalize_notification(<<"item/completed">>, #{<<"item">> := Item} = Params) ->
    normalize_item_completed(maps:get(<<"type">>, Item, <<>>), Item, Params);
normalize_notification(<<"item/completed">>, Params) ->
    #{type => raw, raw => Params,
      timestamp => erlang:system_time(millisecond)};

%% Turn lifecycle
normalize_notification(<<"turn/completed">>, Params) ->
    Status = maps:get(<<"status">>, Params, <<>>),
    ErrorMsg = case maps:find(<<"error">>, Params) of
        {ok, E} when is_binary(E) -> E;
        {ok, E} when is_map(E) -> maps:get(<<"message">>, E, <<>>);
        _ -> <<>>
    end,
    Base = #{type => result,
             content => ErrorMsg,
             timestamp => erlang:system_time(millisecond),
             raw => Params},
    maybe_put(subtype, Status, Base);

normalize_notification(<<"turn/started">>, Params) ->
    #{type => system,
      content => <<"turn started">>,
      subtype => <<"turn_started">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% Command execution output delta
normalize_notification(<<"item/commandExecution/outputDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => stream_event,
      content => Delta,
      subtype => <<"command_output">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% File change output delta
normalize_notification(<<"item/fileChange/outputDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => stream_event,
      content => Delta,
      subtype => <<"file_output">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% Reasoning/thinking text delta
normalize_notification(<<"item/reasoning/textDelta">>, Params) ->
    Delta = maps:get(<<"delta">>, Params, <<>>),
    #{type => thinking,
      content => Delta,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% Error notification
normalize_notification(<<"error">>, Params) ->
    Msg = maps:get(<<"message">>, Params, <<>>),
    Base = #{type => error,
             content => Msg,
             timestamp => erlang:system_time(millisecond),
             raw => Params},
    case maps:find(<<"willRetry">>, Params) of
        {ok, WR} -> Base#{subtype => if WR -> <<"will_retry">>; true -> <<"final">> end};
        error -> Base
    end;

%% Thread status changed
normalize_notification(<<"thread/status/changed">>, Params) ->
    Status = maps:get(<<"status">>, Params, <<>>),
    #{type => system,
      content => <<"thread status: ", Status/binary>>,
      subtype => <<"thread_status_changed">>,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

%% Catch-all — preserve unknown notifications as raw
normalize_notification(_Method, Params) ->
    #{type => raw,
      raw => Params,
      timestamp => erlang:system_time(millisecond)}.

%%--------------------------------------------------------------------
%% Internal: item/started normalization
%%--------------------------------------------------------------------

-spec normalize_item_started(binary(), map(), map()) -> agent_wire:message().
normalize_item_started(<<"AgentMessage">>, Item, Params) ->
    Content = maps:get(<<"content">>, Item,
                  maps:get(<<"text">>, Item, <<>>)),
    #{type => text,
      content => Content,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

normalize_item_started(<<"CommandExecution">>, Item, Params) ->
    #{type => tool_use,
      tool_name => maps:get(<<"command">>, Item,
                       maps:get(<<"callId">>, Item, <<"command">>)),
      tool_input => maps:get(<<"args">>, Item, #{}),
      timestamp => erlang:system_time(millisecond),
      raw => Params};

normalize_item_started(<<"FileChange">>, Item, Params) ->
    #{type => tool_use,
      tool_name => maps:get(<<"filePath">>, Item, <<"file_change">>),
      tool_input => #{<<"action">> => maps:get(<<"action">>, Item, <<>>)},
      timestamp => erlang:system_time(millisecond),
      raw => Params};

normalize_item_started(_Type, _Item, Params) ->
    #{type => raw, raw => Params,
      timestamp => erlang:system_time(millisecond)}.

%%--------------------------------------------------------------------
%% Internal: item/completed normalization
%%--------------------------------------------------------------------

-spec normalize_item_completed(binary(), map(), map()) -> agent_wire:message().
normalize_item_completed(<<"CommandExecution">>, Item, Params) ->
    Output = maps:get(<<"output">>, Item, <<>>),
    #{type => tool_result,
      tool_name => maps:get(<<"command">>, Item,
                       maps:get(<<"callId">>, Item, <<"command">>)),
      content => Output,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

normalize_item_completed(<<"FileChange">>, Item, Params) ->
    Output = maps:get(<<"output">>, Item, <<>>),
    #{type => tool_result,
      tool_name => maps:get(<<"filePath">>, Item, <<"file_change">>),
      content => Output,
      timestamp => erlang:system_time(millisecond),
      raw => Params};

normalize_item_completed(_Type, _Item, Params) ->
    #{type => raw, raw => Params,
      timestamp => erlang:system_time(millisecond)}.

%%====================================================================
%% Wire Param Builders
%%====================================================================

%% @doc Build params for thread/start request.
-spec thread_start_params(map()) -> map().
thread_start_params(Opts) ->
    M0 = #{},
    M1 = maybe_put_opt(<<"ephemeral">>, ephemeral, Opts, M0),
    M2 = maybe_put_opt(<<"baseInstructions">>, base_instructions, Opts, M1),
    maybe_put_opt(<<"developerInstructions">>, developer_instructions, Opts, M2).

%% @doc Build params for turn/start request with string prompt.
%%      Auto-wraps a binary prompt in a Text UserInput list.
-spec turn_start_params(binary(), binary() | [user_input()]) -> map().
turn_start_params(ThreadId, Prompt) when is_binary(Prompt) ->
    turn_start_params(ThreadId, [text_input(Prompt)], #{});
turn_start_params(ThreadId, Inputs) when is_list(Inputs) ->
    turn_start_params(ThreadId, Inputs, #{}).

%% @doc Build params for turn/start request with explicit options.
-spec turn_start_params(binary(), binary() | [user_input()], map()) -> map().
turn_start_params(ThreadId, Prompt, Opts) when is_binary(Prompt) ->
    turn_start_params(ThreadId, [text_input(Prompt)], Opts);
turn_start_params(ThreadId, Inputs, Opts) when is_list(Inputs) ->
    M0 = #{<<"threadId">> => ThreadId, <<"userInput">> => Inputs},
    M1 = maybe_put_opt(<<"model">>, model, Opts, M0),
    M2 = maybe_put_opt(<<"askForApproval">>, approval_policy, Opts, M1),
    M3 = maybe_put_opt(<<"sandboxMode">>, sandbox_mode, Opts, M2),
    maybe_put_opt(<<"outputFormat">>, output_format, Opts, M3).

%% @doc Build params for initialize request.
-spec initialize_params(map()) -> map().
initialize_params(Opts) ->
    ClientInfo = #{
        <<"name">> => <<"beam_agent_sdk">>,
        <<"version">> => <<"0.1.0">>
    },
    M0 = #{<<"clientInfo">> => ClientInfo},
    M1 = maybe_put_opt(<<"model">>, model, Opts, M0),
    M2 = maybe_put_opt(<<"askForApproval">>, approval_policy, Opts, M1),
    M3 = maybe_put_opt(<<"sandboxMode">>, sandbox_mode, Opts, M2),
    maybe_put_opt(<<"outputFormat">>, output_format, Opts, M3).

%%====================================================================
%% Approval Response Builders
%%====================================================================

%% @doc Build response map for command execution approval.
-spec command_approval_response(approval_decision()) -> map().
command_approval_response(Decision) ->
    #{<<"decision">> => encode_approval_decision(Decision)}.

%% @doc Build response map for file change approval.
-spec file_approval_response(file_approval_decision()) -> map().
file_approval_response(Decision) ->
    #{<<"decision">> => encode_approval_decision(Decision)}.

%%====================================================================
%% Text Input Helper
%%====================================================================

%% @doc Create a Text UserInput for turn/start.
-spec text_input(binary()) -> user_input().
text_input(Text) when is_binary(Text) ->
    #{type => <<"Text">>, text => Text}.

%%====================================================================
%% Enum Encoding/Parsing
%%====================================================================

%% @doc Parse a wire approval decision string to atom.
-spec parse_approval_decision(binary()) -> approval_decision().
parse_approval_decision(<<"accept">>)            -> accept;
parse_approval_decision(<<"acceptForSession">>)  -> accept_for_session;
parse_approval_decision(<<"decline">>)           -> decline;
parse_approval_decision(<<"cancel">>)            -> cancel;
parse_approval_decision(_)                       -> decline.

%% @doc Encode an approval decision atom to wire format.
-spec encode_approval_decision(approval_decision()) -> binary().
encode_approval_decision(accept)             -> <<"accept">>;
encode_approval_decision(accept_for_session) -> <<"acceptForSession">>;
encode_approval_decision(decline)            -> <<"decline">>;
encode_approval_decision(cancel)             -> <<"cancel">>.

%% @doc Encode AskForApproval enum (kebab-case on wire).
-spec encode_ask_for_approval(ask_for_approval()) -> binary().
encode_ask_for_approval(untrusted)  -> <<"untrusted">>;
encode_ask_for_approval(on_failure) -> <<"on-failure">>;
encode_ask_for_approval(on_request) -> <<"on-request">>;
encode_ask_for_approval(reject)     -> <<"reject">>;
encode_ask_for_approval(never)      -> <<"never">>.

%% @doc Encode SandboxMode enum (kebab-case on wire).
-spec encode_sandbox_mode(sandbox_mode()) -> binary().
encode_sandbox_mode(read_only)          -> <<"read-only">>;
encode_sandbox_mode(workspace_write)    -> <<"workspace-write">>;
encode_sandbox_mode(danger_full_access) -> <<"danger-full-access">>.

%%====================================================================
%% Internal Helpers
%%====================================================================

-spec maybe_put(atom(), term(), map()) -> map().
maybe_put(_Key, <<>>, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

-spec maybe_put_opt(binary(), atom(), map(), map()) -> map().
maybe_put_opt(WireKey, OptKey, Opts, Map) ->
    case maps:find(OptKey, Opts) of
        {ok, V} -> Map#{WireKey => V};
        error   -> Map
    end.
