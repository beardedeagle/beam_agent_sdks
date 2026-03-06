-module(gemini_cli_protocol).

-moduledoc """
Gemini CLI wire protocol normalization -- pure functions.

Maps Gemini CLI JSON events to `agent_wire:message()`. No processes,
no state. All `maps:get` calls use defaults for defensive coding.

Gemini CLI wire protocol event types:

| Wire Event | Normalized Type |
|---|---|
| `init` | system message with `session_id` and `model` (subtype: init) |
| `message/user` | user message |
| `message/assistant` (`delta=true`) | text message (content is delta) |
| `message/assistant` (`delta=false`) | text message (content is full text) |
| `tool_use` | tool_use message |
| `tool_result/success` | tool_result message |
| `tool_result/error` | error message |
| `error/warning` | system message with subtype warning |
| `error/error` | error message |
| `result/success` | result message with stats |
| `result/error` | error message |
| unknown | raw message |
""".

-export([
    normalize_event/1,
    parse_stats/1,
    exit_code_to_error/1
]).

%%====================================================================
%% API
%%====================================================================

-doc """
Normalize a raw decoded Gemini CLI JSON event map into an
`agent_wire:message()`. Dispatches on the `"type"` field.
All fields use defaults for defensive coding.
""".
-spec normalize_event(map()) -> agent_wire:message().
normalize_event(#{<<"type">> := <<"init">>} = Raw) ->
    SessionId = maps:get(<<"session_id">>, Raw, <<>>),
    Model = maps:get(<<"model">>, Raw, <<>>),
    #{
        type      => system,
        subtype   => <<"init">>,
        session_id => SessionId,
        model     => Model,
        content   => <<>>,
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"message">>, <<"role">> := <<"user">>} = Raw) ->
    #{
        type      => user,
        content   => maps:get(<<"content">>, Raw, <<>>),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"message">>, <<"role">> := <<"assistant">>} = Raw) ->
    #{
        type      => text,
        content   => maps:get(<<"content">>, Raw, <<>>),
        delta     => maps:get(<<"delta">>, Raw, false),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"tool_use">>} = Raw) ->
    #{
        type        => tool_use,
        tool_name   => maps:get(<<"tool_name">>, Raw, <<>>),
        tool_input  => maps:get(<<"parameters">>, Raw, #{}),
        tool_use_id => maps:get(<<"tool_id">>, Raw, <<>>),
        raw         => Raw,
        timestamp   => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"tool_result">>, <<"status">> := <<"success">>} = Raw) ->
    #{
        type        => tool_result,
        content     => maps:get(<<"output">>, Raw, <<>>),
        tool_use_id => maps:get(<<"tool_id">>, Raw, <<>>),
        raw         => Raw,
        timestamp   => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"tool_result">>, <<"status">> := <<"error">>} = Raw) ->
    #{
        type      => error,
        content   => maps:get(<<"output">>, Raw,
                        maps:get(<<"message">>, Raw, <<"tool_result error">>)),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"error">>, <<"severity">> := <<"warning">>} = Raw) ->
    #{
        type      => system,
        subtype   => <<"warning">>,
        content   => maps:get(<<"message">>, Raw, <<>>),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"error">>} = Raw) ->
    #{
        type      => error,
        content   => maps:get(<<"message">>, Raw, <<>>),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"result">>, <<"status">> := <<"success">>} = Raw) ->
    StatsRaw = maps:get(<<"stats">>, Raw, #{}),
    Stats = parse_stats(StatsRaw),
    #{
        type      => result,
        content   => maps:get(<<"content">>, Raw, <<>>),
        stats     => Stats,
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(#{<<"type">> := <<"result">>, <<"status">> := <<"error">>} = Raw) ->
    #{
        type      => error,
        content   => maps:get(<<"message">>, Raw,
                        maps:get(<<"content">>, Raw, <<"result error">>)),
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    };

normalize_event(Raw) when is_map(Raw) ->
    #{
        type      => raw,
        raw       => Raw,
        timestamp => erlang:system_time(millisecond)
    }.

-doc "Extract stats from a Gemini CLI result stats map. Returns a normalized map with atom keys and numeric defaults.".
-spec parse_stats(map()) -> map().
parse_stats(Stats) when is_map(Stats) ->
    #{
        tokens_in    => maps:get(<<"tokens_in">>, Stats, 0),
        tokens_out   => maps:get(<<"tokens_out">>, Stats, 0),
        duration_ms  => maps:get(<<"duration_ms">>, Stats, 0),
        tool_calls   => maps:get(<<"tool_calls">>, Stats, 0)
    };
parse_stats(_) ->
    #{tokens_in => 0, tokens_out => 0, duration_ms => 0, tool_calls => 0}.

-doc "Map a Gemini CLI exit code to a descriptive binary reason. Exit codes sourced from the Gemini CLI documentation.".
-spec exit_code_to_error(integer()) -> binary().
exit_code_to_error(0)   -> <<"success">>;
exit_code_to_error(41)  -> <<"auth_error">>;
exit_code_to_error(42)  -> <<"input_error">>;
exit_code_to_error(52)  -> <<"config_error">>;
exit_code_to_error(130) -> <<"cancelled">>;
exit_code_to_error(N)   ->
    iolist_to_binary(io_lib:format("unknown_error: ~p", [N])).
