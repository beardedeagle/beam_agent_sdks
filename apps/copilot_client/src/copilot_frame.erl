-module(copilot_frame).

-moduledoc """
Content-Length frame parser for the Copilot wire protocol.

The Copilot CLI uses LSP-style Content-Length framing (NOT JSONL):

```
Content-Length: <N>\r\n\r\n<N bytes of JSON>
```

This module provides pure functions for extracting complete
messages from a byte buffer and encoding outgoing messages.
No processes -- used by copilot_session for port I/O.

Uses OTP 27+ `json` module -- no external JSON dependency.
""".

-export([
    extract_message/1,
    extract_messages/1,
    encode_message/1
]).

-export_type([
    extract_result/0
]).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

-type extract_result() ::
    {ok, map(), Remaining :: binary()}
  | incomplete
  | {error, term()}.

%%====================================================================
%% Extraction API
%%====================================================================

-doc """
Extract one complete Content-Length framed message from the buffer.

Returns:
- `{ok, DecodedMap, RemainingBuffer}` -- complete message decoded
- `incomplete` -- not enough data yet (need more bytes)
- `{error, Reason}` -- parse error (bad header, invalid JSON)
""".
-spec extract_message(binary()) -> extract_result().
extract_message(Buffer) when byte_size(Buffer) =:= 0 ->
    incomplete;
extract_message(Buffer) ->
    case find_header_boundary(Buffer) of
        nomatch ->
            %% No complete header yet. Guard against unbounded header
            %% accumulation — if the buffer has >4KB without \r\n\r\n,
            %% something is very wrong.
            case byte_size(Buffer) > 4096 of
                true  -> {error, {header_too_large, byte_size(Buffer)}};
                false -> incomplete
            end;
        {HeaderEnd, BodyStart} ->
            Header = binary:part(Buffer, 0, HeaderEnd),
            case parse_content_length(Header) of
                {ok, ContentLength} ->
                    Available = byte_size(Buffer) - BodyStart,
                    case Available >= ContentLength of
                        true ->
                            Body = binary:part(Buffer, BodyStart, ContentLength),
                            RestStart = BodyStart + ContentLength,
                            Rest = binary:part(Buffer, RestStart,
                                               byte_size(Buffer) - RestStart),
                            decode_body(Body, Rest);
                        false ->
                            incomplete
                    end;
                {error, _} = Err ->
                    Err
            end
    end.

-doc """
Extract all complete messages from the buffer (batch mode).
Returns a list of decoded maps and the remaining buffer.
""".
-spec extract_messages(binary()) -> {[map()], binary()}.
extract_messages(Buffer) ->
    extract_messages_acc(Buffer, []).

%%====================================================================
%% Encoding API
%%====================================================================

-doc """
Encode a JSON map as a Content-Length framed message.
Returns iodata suitable for `port_command/2`.
""".
-spec encode_message(map()) -> iodata().
encode_message(Msg) when is_map(Msg) ->
    BodyBytes = iolist_to_binary(json:encode(Msg)),
    Length = byte_size(BodyBytes),
    [<<"Content-Length: ">>, integer_to_binary(Length),
     <<"\r\n\r\n">>, BodyBytes].

%%====================================================================
%% Internal Functions
%%====================================================================

%% Find the \r\n\r\n boundary that separates header from body.
%% Returns {HeaderEndOffset, BodyStartOffset} or nomatch.
-spec find_header_boundary(binary()) -> {non_neg_integer(), non_neg_integer()} | nomatch.
find_header_boundary(Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        nomatch -> nomatch;
        {Pos, 4} -> {Pos, Pos + 4}
    end.

%% Parse Content-Length value from header section.
%% Handles case-insensitive header names per HTTP convention.
-spec parse_content_length(binary()) -> {ok, non_neg_integer()} | {error, term()}.
parse_content_length(Header) ->
    Lines = binary:split(Header, <<"\r\n">>, [global]),
    parse_cl_lines(Lines).

-spec parse_cl_lines([binary()]) -> {ok, non_neg_integer()} | {error, term()}.
parse_cl_lines([]) ->
    {error, missing_content_length};
parse_cl_lines([Line | Rest]) ->
    Lower = string:lowercase(Line),
    case Lower of
        <<"content-length:", _/binary>> ->
            %% Extract value from original line (preserving case is irrelevant
            %% for the number, but we split the original for accuracy)
            case binary:split(Line, <<":">>) of
                [_, ValueBin] ->
                    Trimmed = string:trim(ValueBin),
                    try binary_to_integer(Trimmed) of
                        N when N >= 0 -> {ok, N};
                        N -> {error, {invalid_content_length, N}}
                    catch
                        error:badarg ->
                            {error, {invalid_content_length, Trimmed}}
                    end;
                _ ->
                    {error, {malformed_header, Line}}
            end;
        _ ->
            parse_cl_lines(Rest)
    end.

%% Decode JSON body into a map.
-spec decode_body(binary(), binary()) -> extract_result().
decode_body(Body, Rest) ->
    try json:decode(Body) of
        Decoded when is_map(Decoded) ->
            {ok, Decoded, Rest};
        _Other ->
            {error, {invalid_json, not_object}}
    catch
        error:Reason ->
            {error, {json_decode, Reason}}
    end.

%% Accumulator for extract_messages/1.
-spec extract_messages_acc(binary(), [map()]) -> {[map()], binary()}.
extract_messages_acc(Buffer, Acc) ->
    case extract_message(Buffer) of
        {ok, Msg, Rest} ->
            extract_messages_acc(Rest, [Msg | Acc]);
        incomplete ->
            {lists:reverse(Acc), Buffer};
        {error, _Reason} ->
            %% On error, stop extraction and return what we have
            {lists:reverse(Acc), Buffer}
    end.
