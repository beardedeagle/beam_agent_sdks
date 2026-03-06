-module(opencode_sse).

-moduledoc """
Pure SSE (Server-Sent Events) frame parser.

No processes. Operates on raw bytes. Implements the standard SSE
parsing rules (RFC 8895 / WHATWG EventSource spec):

- Buffer incoming data, split on newlines
- Lines starting with `:` are comments (ignored, used for heartbeats)
- `data: <value>` accumulates data (multiple lines joined with `\n`)
- `event: <value>` sets the event type
- `id: <value>` sets the event ID
- Empty line flushes the accumulated event

Returns a list of complete events and the remaining parse state
for the next call. Handles both `\n` and `\r\n` line endings.

The parse state is opaque -- use `new_state/0` to create the initial
state and pass the returned state to subsequent calls.
""".

-export([new_state/0, parse_chunk/2, buffer_size/1]).

-export_type([sse_event/0, parse_state/0]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type sse_event() :: #{data := binary(), event => binary(), id => binary()}.

%% Opaque parse state: {BufferBinary, EventAccumulator}.
%% Callers should not inspect or construct this directly.
-opaque parse_state() :: {binary(), term()}.

%%--------------------------------------------------------------------
%% Internal state for accumulating one event
%%--------------------------------------------------------------------

-record(evt, {
    event_type  = undefined :: binary() | undefined,
    event_id    = undefined :: binary() | undefined,
    data_lines  = []        :: [binary()]
}).

%%====================================================================
%% Public API
%%====================================================================

-doc """
Create a fresh parse state.
Call this once at session start, then pass the returned state
from each `parse_chunk/2` call to the next.
""".
-spec new_state() -> parse_state().
new_state() -> {<<>>, #evt{}}.

-doc """
Return the current internal buffer size in bytes.
Useful for enforcing buffer overflow limits at the session level.
""".
-spec buffer_size(parse_state()) -> non_neg_integer().
buffer_size({Buffer, _Evt}) -> byte_size(Buffer).

-doc """
Parse a new chunk of SSE data with the current parse state.

Concatenates the chunk onto the internal buffer, splits on
newline boundaries, processes field lines, and flushes on
empty lines.

Returns `{CompletedEvents, NewParseState}`.
The parse state carries both the partial-line buffer and
the in-progress event accumulator across calls.
""".
-spec parse_chunk(binary(), parse_state()) -> {[sse_event()], parse_state()}.
parse_chunk(Chunk, {Buffer, Evt}) ->
    Full = <<Buffer/binary, Chunk/binary>>,
    {Lines, Remaining} = split_lines(Full),
    {Events, FinalEvt} = process_lines(Lines, Evt, []),
    {Events, {Remaining, FinalEvt}}.

%%====================================================================
%% Internal: Line splitting
%%====================================================================

%% Split binary on `\n` boundaries (stripping `\r` from `\r\n`).
%% Returns `{CompleteLines, PartialTail}` where PartialTail is
%% everything after the last `\n` (may be empty binary).
-spec split_lines(binary()) -> {[binary()], binary()}.
split_lines(Data) ->
    split_lines(Data, [], <<>>).

-spec split_lines(binary(), [binary()], binary()) -> {[binary()], binary()}.
split_lines(<<>>, Lines, Current) ->
    {lists:reverse(Lines), Current};
split_lines(<<$\r, $\n, Rest/binary>>, Lines, Current) ->
    split_lines(Rest, [Current | Lines], <<>>);
split_lines(<<$\n, Rest/binary>>, Lines, Current) ->
    split_lines(Rest, [Current | Lines], <<>>);
split_lines(<<Byte, Rest/binary>>, Lines, Current) ->
    split_lines(Rest, Lines, <<Current/binary, Byte>>).

%%====================================================================
%% Internal: Line processing
%%====================================================================

%% Process a list of complete lines, accumulating event state.
%% Returns `{CompletedEvents, FinalEventAccumulator}`.
%%
%% An empty line flushes the current event to the output list.
%% Field lines update the current event accumulator.
%% Comment lines (`:` prefix) are silently ignored.
-spec process_lines([binary()], #evt{}, [sse_event()]) ->
    {[sse_event()], #evt{}}.
process_lines([], Evt, Events) ->
    {lists:reverse(Events), Evt};
process_lines([Line | Rest], Evt, Events) ->
    case Line of
        <<>> ->
            %% Empty line — flush current event
            case flush_event(Evt) of
                skip ->
                    process_lines(Rest, #evt{}, Events);
                Event ->
                    process_lines(Rest, #evt{}, [Event | Events])
            end;
        <<$:, _/binary>> ->
            %% Comment line — ignore (used for heartbeats)
            process_lines(Rest, Evt, Events);
        _ ->
            %% Field line — parse and update accumulator
            Evt1 = apply_field(Line, Evt),
            process_lines(Rest, Evt1, Events)
    end.

%%====================================================================
%% Internal: Field parsing
%%====================================================================

%% Parse a single field line and update the event accumulator.
%% SSE field syntax: `field: value` or `field` (value defaults to "").
-spec apply_field(binary(), #evt{}) -> #evt{}.
apply_field(Line, Evt) ->
    case binary:split(Line, <<": ">>) of
        [Field, Value] ->
            apply_named_field(Field, Value, Evt);
        [Field] ->
            %% Field with no value — treat as empty string value
            apply_named_field(Field, <<>>, Evt);
        [Field | _Rest] ->
            apply_named_field(Field, <<>>, Evt)
    end.

-spec apply_named_field(binary(), binary(), #evt{}) -> #evt{}.
apply_named_field(<<"data">>, Value, Evt) ->
    Evt#evt{data_lines = [Value | Evt#evt.data_lines]};
apply_named_field(<<"event">>, Value, Evt) ->
    Evt#evt{event_type = Value};
apply_named_field(<<"id">>, Value, Evt) ->
    Evt#evt{event_id = Value};
apply_named_field(<<"retry">>, _Value, Evt) ->
    %% retry field is for reconnection timing — ignore
    Evt;
apply_named_field(_Other, _Value, Evt) ->
    %% Unknown field — ignore per spec
    Evt.

%%====================================================================
%% Internal: Event flushing
%%====================================================================

%% Flush the accumulated event state into an sse_event() map.
%% Returns `skip` when there is no data to emit.
%%
%% Per spec, data lines are joined with `\n`. An event with no
%% data lines is discarded.
-spec flush_event(#evt{}) -> sse_event() | skip.
flush_event(#evt{data_lines = []}) ->
    skip;
flush_event(#evt{data_lines = DataLines, event_type = EventType,
                  event_id = EventId}) ->
    Data = join_data_lines(lists:reverse(DataLines)),
    Base = #{data => Data},
    M0 = case EventType of
        undefined -> Base;
        ET -> Base#{event => ET}
    end,
    case EventId of
        undefined -> M0;
        EId -> M0#{id => EId}
    end.

%% Join data lines with `\n` per SSE spec.
-spec join_data_lines([binary()]) -> binary().
join_data_lines([]) -> <<>>;
join_data_lines([Single]) -> Single;
join_data_lines(Lines) ->
    lists:foldl(fun
        (Line, <<>>) -> Line;
        (Line, Acc) -> <<Acc/binary, $\n, Line/binary>>
    end, <<>>, Lines).
