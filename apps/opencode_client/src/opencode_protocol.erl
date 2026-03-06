-module(opencode_protocol).

-moduledoc """
Pure protocol mapping: OpenCode SSE events to `agent_wire:message()`.

No processes. All functions are pure transformations. Dispatches
on SSE event type, then sub-dispatches on part type / status.

Mapping table:

| SSE event type          | Condition                  | agent_wire type    |
|-------------------------|----------------------------|--------------------|
| message.part.updated    | part.type=text, delta      | text               |
| message.part.updated    | part.type=text, no delta   | text               |
| message.part.updated    | part.type=reasoning        | thinking           |
| message.part.updated    | part.type=tool, pending    | tool_use           |
| message.part.updated    | part.type=tool, running    | tool_use           |
| message.part.updated    | part.type=tool, completed  | tool_result        |
| message.part.updated    | part.type=tool, error      | error              |
| message.part.updated    | part.type=step-start       | system             |
| message.part.updated    | part.type=step-finish      | system             |
| message.updated         | assistant with error       | error              |
| session.idle            | during active query        | result             |
| session.error           | --                         | error              |
| permission.updated      | --                         | control_request    |
| server.heartbeat        | --                         | skip               |
| server.connected        | --                         | system             |
| all others              | --                         | raw                |
""".

-export([
    normalize_event/1,
    build_prompt_input/2,
    build_permission_reply/2,
    parse_session/1
]).

-export_type([]).

-dialyzer({no_underspecs, [
    parse_session/1,
    maybe_add_model/2,
    maybe_add_output_format/2
]}).
-dialyzer({no_extra_return, [
    normalize_part_updated/2,
    dispatch_part_type/4,
    normalize_tool_part/5
]}).

%%====================================================================
%% Public API
%%====================================================================

-doc """
Normalize an SSE event map into an `agent_wire:message()` or `skip`.

The input map has keys:
- `data` -- the JSON-decoded payload map
- `event` -- the SSE event type binary (e.g. `"message.part.updated"`)
- `id` -- optional SSE event id

The event type binary is extracted from the SSE `event` field.
If the field is absent, the event type defaults to `"unknown"`.
""".
-spec normalize_event(map()) -> agent_wire:message() | skip.
normalize_event(SseEvent) ->
    EventType = maps:get(event, SseEvent, <<"unknown">>),
    Payload   = maps:get(data, SseEvent, #{}),
    Now       = erlang:system_time(millisecond),
    dispatch_event(EventType, Payload, Now).

-doc "Build the JSON body map for `POST /session/:id/message`.".
-spec build_prompt_input(binary(), map()) -> map().
build_prompt_input(Prompt, Opts) ->
    Parts = [#{<<"type">> => <<"text">>, <<"text">> => Prompt}],
    Base = #{<<"parts">> => Parts},
    M1 = maybe_add_model(Base, Opts),
    maybe_add_output_format(M1, Opts).

-doc "Build the JSON body map for `POST /permission/:id/reply`.".
-spec build_permission_reply(binary(), binary()) -> map().
build_permission_reply(PermId, Decision) ->
    #{<<"id">> => PermId, <<"decision">> => Decision}.

-doc "Parse a session object returned by `POST /session`.".
-spec parse_session(map()) -> map().
parse_session(Raw) when is_map(Raw) ->
    #{
        id        => maps:get(<<"id">>, Raw, undefined),
        directory => maps:get(<<"directory">>, Raw, undefined),
        model     => maps:get(<<"model">>, Raw, undefined),
        raw       => Raw
    }.

%%====================================================================
%% Internal: Event dispatch
%%====================================================================

-spec dispatch_event(binary(), map(), integer()) -> agent_wire:message() | skip.
dispatch_event(<<"message.part.updated">>, Payload, Now) ->
    normalize_part_updated(Payload, Now);

dispatch_event(<<"message.updated">>, Payload, Now) ->
    %% Assistant message with error field
    case maps:get(<<"error">>, Payload, undefined) of
        undefined ->
            #{type => raw, raw => Payload, timestamp => Now};
        ErrorVal ->
            ErrName = case is_map(ErrorVal) of
                true  -> maps:get(<<"name">>, ErrorVal, <<"unknown_error">>);
                false -> <<"message_error">>
            end,
            ErrData = case is_map(ErrorVal) of
                true  -> maps:get(<<"data">>, ErrorVal, <<>>);
                false -> <<>>
            end,
            Content = iolist_to_binary([ErrName, <<": ">>, to_binary(ErrData)]),
            #{type => error, content => Content, raw => Payload, timestamp => Now}
    end;

dispatch_event(<<"session.idle">>, Payload, Now) ->
    %% session.idle signals query completion — emit a result message
    SessionId = maps:get(<<"id">>, Payload, undefined),
    Base = #{type => result, content => <<>>, timestamp => Now, raw => Payload},
    case SessionId of
        undefined -> Base;
        SId       -> Base#{session_id => SId}
    end;

dispatch_event(<<"session.error">>, Payload, Now) ->
    ErrMsg = maps:get(<<"message">>, Payload,
                maps:get(<<"error">>, Payload, <<"session error">>)),
    Content = to_binary(ErrMsg),
    #{type => error, content => Content, raw => Payload, timestamp => Now};

dispatch_event(<<"permission.updated">>, Payload, Now) ->
    PermId  = maps:get(<<"id">>, Payload, undefined),
    ReqInfo = maps:get(<<"request">>, Payload, Payload),
    #{type       => control_request,
      request_id => to_binary(PermId),
      request    => ReqInfo,
      raw        => Payload,
      timestamp  => Now};

dispatch_event(<<"server.heartbeat">>, _Payload, _Now) ->
    skip;

dispatch_event(<<"server.connected">>, Payload, Now) ->
    #{type      => system,
      subtype   => <<"connected">>,
      content   => <<>>,
      raw       => Payload,
      timestamp => Now};

dispatch_event(_Other, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.

%%====================================================================
%% Internal: message.part.updated dispatch
%%====================================================================

-spec normalize_part_updated(map(), integer()) -> agent_wire:message() | skip.
normalize_part_updated(Payload, Now) ->
    Part     = maps:get(<<"part">>, Payload, Payload),
    PartType = maps:get(<<"type">>, Part, <<>>),
    dispatch_part_type(PartType, Part, Payload, Now).

-spec dispatch_part_type(binary(), map(), map(), integer()) ->
    agent_wire:message() | skip.
dispatch_part_type(<<"text">>, Part, Payload, Now) ->
    %% Delta takes precedence over full text
    Content = case maps:get(<<"delta">>, Part, undefined) of
        undefined -> maps:get(<<"text">>, Part, <<>>);
        Delta     -> to_binary(Delta)
    end,
    #{type => text, content => Content, raw => Payload, timestamp => Now};

dispatch_part_type(<<"reasoning">>, Part, Payload, Now) ->
    Content = maps:get(<<"text">>, Part,
                maps:get(<<"reasoning">>, Part, <<>>)),
    #{type => thinking, content => to_binary(Content),
      raw => Payload, timestamp => Now};

dispatch_part_type(<<"tool">>, Part, Payload, Now) ->
    State  = maps:get(<<"state">>, Part, #{}),
    Status = maps:get(<<"status">>, State,
                maps:get(<<"status">>, Part, <<"pending">>)),
    normalize_tool_part(Status, Part, State, Payload, Now);

dispatch_part_type(<<"step-start">>, _Part, Payload, Now) ->
    #{type => system, subtype => <<"step_start">>,
      content => <<>>, raw => Payload, timestamp => Now};

dispatch_part_type(<<"step-finish">>, Part, Payload, Now) ->
    %% Carry cost/token info if present
    Cost   = maps:get(<<"cost">>, Part, undefined),
    Tokens = maps:get(<<"tokens">>, Part, undefined),
    Base   = #{type => system, subtype => <<"step_finish">>,
               content => <<>>, raw => Payload, timestamp => Now},
    M0 = case Cost   of undefined -> Base; C -> Base#{total_cost_usd => C} end,
    M1 = case Tokens of undefined -> M0;  T -> M0#{usage => T} end,
    M1;

dispatch_part_type(_Other, _Part, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.

%%====================================================================
%% Internal: tool part status dispatch
%%====================================================================

-spec normalize_tool_part(binary(), map(), map(), map(), integer()) ->
    agent_wire:message() | skip.
normalize_tool_part(Status, Part, State, Payload, Now)
  when Status =:= <<"pending">>; Status =:= <<"running">> ->
    ToolName  = maps:get(<<"tool">>, State,
                    maps:get(<<"tool">>, Part, <<>>)),
    ToolInput = maps:get(<<"input">>, State,
                    maps:get(<<"input">>, Part, #{})),
    #{type       => tool_use,
      tool_name  => to_binary(ToolName),
      tool_input => ensure_map(ToolInput),
      raw        => Payload,
      timestamp  => Now};

normalize_tool_part(<<"completed">>, Part, State, Payload, Now) ->
    ToolName = maps:get(<<"tool">>, State,
                   maps:get(<<"tool">>, Part, <<>>)),
    Output   = maps:get(<<"output">>, State,
                   maps:get(<<"output">>, Part, <<>>)),
    #{type      => tool_result,
      tool_name => to_binary(ToolName),
      content   => to_binary(Output),
      raw       => Payload,
      timestamp => Now};

normalize_tool_part(<<"error">>, Part, State, Payload, Now) ->
    ErrMsg = maps:get(<<"error">>, State,
                maps:get(<<"error">>, Part, <<"tool error">>)),
    #{type => error, content => to_binary(ErrMsg),
      raw => Payload, timestamp => Now};

normalize_tool_part(_OtherStatus, _Part, _State, Payload, Now) ->
    #{type => raw, raw => Payload, timestamp => Now}.

%%====================================================================
%% Internal: Helpers
%%====================================================================

-spec maybe_add_model(map(), map()) -> map().
maybe_add_model(Base, Opts) ->
    case maps:get(model, Opts, undefined) of
        undefined -> Base;
        Model when is_map(Model) ->
            Base#{<<"model">> => Model};
        Model when is_binary(Model) ->
            Base#{<<"model">> => Model};
        _ -> Base
    end.

-spec maybe_add_output_format(map(), map()) -> map().
maybe_add_output_format(Base, Opts) ->
    case maps:get(output_format, Opts, undefined) of
        undefined -> Base;
        Format when is_map(Format) -> Base#{<<"outputFormat">> => Format};
        Format when is_atom(Format) -> Base#{<<"outputFormat">> => atom_to_binary(Format)};
        _ -> Base
    end.

-spec to_binary(term()) -> binary().
to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(F) when is_float(F)  ->
    iolist_to_binary(io_lib:format("~g", [F]));
to_binary(L) when is_list(L)   ->
    try iolist_to_binary(L)
    catch _:_ -> list_to_binary(io_lib:format("~p", [L]))
    end;
to_binary(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

-spec ensure_map(term()) -> map().
ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.
