%%%-------------------------------------------------------------------
%%% @doc Common type definitions for the BEAM Agent SDK wire protocols.
%%%
%%% All four wire protocol adapters (Claude Code, Codex CLI, OpenCode,
%%% Gemini CLI) normalize their messages into the types defined here.
%%% This module is pure types and utility functions — no processes.
%%%
%%% Wire protocol cross-referenced against TypeScript Agent SDK v0.2.66
%%% (npm @anthropic-ai/claude-agent-sdk) for protocol fidelity:
%%%   - Result messages use `result` field (not `content`)
%%%   - Every message carries `uuid` and `session_id`
%%%   - All enrichment fields from the official SDK are extracted
%%%   - Stop reasons validated to atoms for pattern matching
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire).

-export([
    normalize_message/1,
    make_request_id/0,
    parse_stop_reason/1,
    parse_permission_mode/1,
    %% Generic message collection loop
    collect_messages/4,
    collect_messages/5
]).

-export_type([
    message/0,
    message_type/0,
    query_opts/0,
    session_opts/0,
    stop_reason/0,
    permission_mode/0,
    system_prompt_config/0,
    permission_result/0,
    receive_fun/0,
    terminal_pred/0
]).

%% Internal helpers where the declared spec is intentionally broader
%% than the implementation (e.g., message() vs exact key set).
-dialyzer({no_underspecs, [add_common_fields/2]}).

%%--------------------------------------------------------------------
%% Type Definitions
%%--------------------------------------------------------------------

%% Normalized message types across all four wire protocols.
%% Cross-referenced against TS SDK v0.2.66 SDKMessage union (20+ types).
-type message_type() :: text
                      | assistant
                      | tool_use
                      | tool_result
                      | system
                      | result
                      | error
                      | user
                      | control
                      | control_request
                      | control_response
                      | stream_event
                      | rate_limit_event
                      | tool_progress
                      | tool_use_summary
                      | thinking
                      | auth_status
                      | prompt_suggestion
                      | raw.

%% Stop reasons from the Claude API (TS SDK: stop_reason field).
%% Validated from binary wire format into atoms for pattern matching.
-type stop_reason() :: end_turn
                     | max_tokens
                     | stop_sequence
                     | refusal
                     | tool_use_stop
                     | unknown_stop.

%% Permission modes supported by the Claude Code CLI.
%% Note: dont_ask is TypeScript-only (not available in Python SDK).
-type permission_mode() :: default
                         | accept_edits
                         | bypass_permissions
                         | plan
                         | dont_ask.

%% System prompt configuration.
%% Either a plain binary (custom prompt replacing default) or a
%% structured preset config with optional append.
%%
%% Since SDK v0.1.0, the default prompt is minimal. Use the
%% claude_code preset to get the full Claude Code system prompt.
-type system_prompt_config() :: binary()
                              | #{type := preset,
                                  preset := binary(),
                                  append => binary()}.

%% Permission handler callback result.
%% Follows TS SDK PermissionResult pattern:
%%   - {allow, UpdatedInput} — approve with optional input modification
%%   - {deny, Reason} — deny with reason message
%%   - {allow, UpdatedInput, RuleUpdate} — approve with rule modification
-type permission_result() :: {allow, map()}
                           | {deny, binary()}
                           | {allow, map(), map()}.

%% Unified message record. Required field: `type`.
%% All other fields are optional and depend on message_type().
%%
%% Common fields (present on all messages when the CLI provides them):
%%   uuid           - Unique message identifier (for correlation, checkpoints)
%%   session_id     - Session this message belongs to
%%
%% Type-specific fields:
%%   text:             content
%%   assistant:        content_blocks, parent_tool_use_id,
%%                     message_id, model, usage, stop_reason_atom, error_info
%%   tool_use:         tool_name, tool_input
%%   tool_result:      tool_name, content
%%   system:           content, subtype, system_info (parsed init metadata)
%%   result:           content (from "result" wire field), duration_ms,
%%                     duration_api_ms, num_turns, session_id, stop_reason,
%%                     stop_reason_atom, usage, model_usage, total_cost_usd,
%%                     is_error, subtype, errors, structured_output,
%%                     permission_denials, fast_mode_state
%%   error:            content
%%   user:             content, parent_tool_use_id, is_replay
%%   control:          raw (legacy)
%%   control_request:  request_id, request
%%   control_response: request_id, response
%%   stream_event:     subtype, content, parent_tool_use_id
%%   thinking:         content
%%   tool_progress:    content, tool_name
%%   tool_use_summary: content
%%   auth_status:      raw
%%   prompt_suggestion: content
%%   rate_limit_event: rate_limit_status, resets_at, rate_limit_type,
%%                     utilization, overage_status, overage_resets_at,
%%                     overage_disabled_reason, is_using_overage,
%%                     surpassed_threshold, raw
%%   raw:              raw (unrecognized, preserved for forward compat)
-type message() :: #{
    type := message_type(),
    content => binary(),
    tool_name => binary(),
    tool_input => map(),
    raw => map(),
    timestamp => integer(),
    %% Common wire fields (on all messages from CLI)
    uuid => binary(),
    session_id => binary(),
    %% Assistant message fields
    content_blocks => [agent_wire_content:content_block()],
    parent_tool_use_id => binary() | null,
    message_id => binary(),
    model => binary(),
    error_info => map(),
    %% System message fields
    system_info => map(),
    %% Result enrichment fields
    duration_ms => non_neg_integer(),
    duration_api_ms => non_neg_integer(),
    num_turns => non_neg_integer(),
    stop_reason => binary(),
    stop_reason_atom => stop_reason(),
    usage => map(),
    model_usage => map(),
    total_cost_usd => number(),
    is_error => boolean(),
    subtype => binary(),
    errors => [binary()],
    structured_output => term(),
    permission_denials => list(),
    fast_mode_state => map(),
    %% User message fields
    is_replay => boolean(),
    %% Control protocol fields
    request_id => binary(),
    request => map(),
    response => map(),
    %% Rate limit event fields (TS SDK SDKRateLimitInfo)
    rate_limit_status => binary(),
    resets_at => number(),
    rate_limit_type => binary(),
    utilization => number(),
    overage_status => binary(),
    overage_resets_at => number(),
    overage_disabled_reason => binary(),
    is_using_overage => boolean(),
    surpassed_threshold => number(),
    %% Thread management (added by agent_wire_threads)
    thread_id => binary()
}.

%% Options for dispatching a query to an agent.
-type query_opts() :: #{
    model => binary(),
    system_prompt => system_prompt_config(),
    allowed_tools => [binary()],
    disallowed_tools => [binary()],
    max_tokens => pos_integer(),
    max_turns => pos_integer(),
    permission_mode => binary() | permission_mode(),
    timeout => timeout(),
    %% Structured output (JSON schema)
    output_format => map(),
    %% Thinking configuration
    thinking => map(),
    effort => binary(),
    %% Cost control
    max_budget_usd => number(),
    %% Subagent selection
    agent => binary()
}.

%% Options for establishing an agent session.
-type session_opts() :: #{
    cli_path => file:filename_all(),
    work_dir => file:filename_all(),
    env => [{string(), string()}],
    buffer_max => pos_integer(),
    queue_max => pos_integer(),
    node => node(),
    model => binary(),
    system_prompt => system_prompt_config(),
    max_turns => pos_integer(),
    session_id => binary(),
    %% Session lifecycle
    resume => boolean(),
    fork_session => boolean(),
    continue => boolean(),
    persist_session => boolean(),
    %% Permission system
    permission_mode => binary() | permission_mode(),
    permission_handler => fun((binary(), map(), map()) -> permission_result()),
    permission_default => allow | deny,  %% Default: deny (fail-closed)
    %% Tools and agents
    allowed_tools => [binary()],
    disallowed_tools => [binary()],
    agents => map(),
    %% MCP servers
    mcp_servers => map(),
    %% SDK MCP servers (in-process tool handlers)
    sdk_mcp_servers => [agent_wire_mcp:sdk_mcp_server()],
    %% MCP handler timeout in milliseconds (default: 30000)
    mcp_handler_timeout => pos_integer(),
    %% SDK-level lifecycle hooks (in-process callbacks)
    sdk_hooks => [agent_wire_hooks:hook_def()],
    %% Structured output
    output_format => map(),
    %% Thinking
    thinking => map(),
    effort => binary(),
    %% Cost
    max_budget_usd => number(),
    %% File checkpointing
    enable_file_checkpointing => boolean(),
    %% Settings
    setting_sources => [binary()],
    %% Plugins
    plugins => [map()],
    %% Hooks
    hooks => map(),
    %% Beta features
    betas => [binary()],
    %% Streaming
    include_partial_messages => boolean(),
    %% Prompt suggestions
    prompt_suggestions => boolean(),
    %% Sandbox
    sandbox => map(),
    %% Debug
    debug => boolean(),
    debug_file => binary(),
    %% Extra CLI arguments (key => value or key => null for flags)
    extra_args => #{binary() => binary() | null},
    %% Client identification (sets CLAUDE_AGENT_SDK_CLIENT_APP env var)
    client_app => binary(),
    %% Codex-specific options
    transport => app_server | exec,
    approval_handler => fun((binary(), map(), map()) -> atom()),
    thread_id => binary(),
    approval_policy => binary(),
    sandbox_mode => binary(),
    base_instructions => binary(),
    developer_instructions => binary(),
    ephemeral => boolean(),
    %% Gemini CLI-specific options
    approval_mode => binary(),
    settings_file => binary(),
    %% OpenCode-specific options
    base_url => binary(),
    directory => binary(),
    auth => {basic, binary(), binary()} | none,
    provider_id => binary(),
    model_id => binary(),
    agent => binary(),
    output_format => text | json_schema,
    %% Copilot-specific options
    protocol_version => pos_integer(),
    tool_handlers => #{binary() => fun()},
    user_input_handler => fun((map(), map()) -> {ok, binary()} | {error, term()})
}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Normalize a raw decoded JSON map into an agent_wire:message().
%%      Adapters call this after decoding their wire-format-specific
%%      JSON to produce the common message type.
%%
%%      Extracts common fields (uuid, session_id) from every message,
%%      then delegates to type-specific field extraction.
%% Spec is intentionally broader than success typing — message() is the
%% API contract for all five adapters, not just the branches here.
-dialyzer({nowarn_function, normalize_message/1}).
-spec normalize_message(map()) -> message().
normalize_message(#{<<"type">> := TypeBin} = Raw) ->
    Type = parse_type(TypeBin),
    Base0 = #{type => Type, timestamp => erlang:system_time(millisecond)},
    Base = add_common_fields(Raw, Base0),
    add_fields(Type, Raw, Base);
normalize_message(Raw) when is_map(Raw) ->
    #{type => raw, raw => Raw, timestamp => erlang:system_time(millisecond)}.

%% @doc Generate a unique request ID for control protocol correlation.
%%      Format: req_COUNTER_HEX (e.g., req_0_a1b2c3d4) matching the
%%      actual Claude Code CLI protocol.
-spec make_request_id() -> binary().
make_request_id() ->
    Seq = erlang:unique_integer([positive, monotonic]),
    Hex = binary:encode_hex(rand:bytes(4), lowercase),
    iolist_to_binary(io_lib:format("req_~b_~s", [Seq, Hex])).

%% @doc Parse a binary stop reason into a typed atom.
%%      Unknown values map to `unknown_stop' for forward compatibility.
-spec parse_stop_reason(binary() | term()) -> stop_reason().
parse_stop_reason(<<"end_turn">>)      -> end_turn;
parse_stop_reason(<<"max_tokens">>)    -> max_tokens;
parse_stop_reason(<<"stop_sequence">>) -> stop_sequence;
parse_stop_reason(<<"refusal">>)       -> refusal;
parse_stop_reason(<<"tool_use">>)      -> tool_use_stop;
parse_stop_reason(_)                   -> unknown_stop.

%% @doc Parse a binary permission mode into a typed atom.
%%      Note: dont_ask is TypeScript-only (not available in Python SDK).
-spec parse_permission_mode(binary() | term()) -> permission_mode().
parse_permission_mode(<<"default">>)           -> default;
parse_permission_mode(<<"acceptEdits">>)       -> accept_edits;
parse_permission_mode(<<"bypassPermissions">>) -> bypass_permissions;
parse_permission_mode(<<"plan">>)              -> plan;
parse_permission_mode(<<"dontAsk">>)           -> dont_ask;
parse_permission_mode(_)                       -> default.

%%--------------------------------------------------------------------
%% Internal: Common field extraction
%%--------------------------------------------------------------------

%% @doc Extract common fields (uuid, session_id) present on all messages
%%      from the CLI. These are essential for message correlation,
%%      session continuity, and file checkpointing.
-spec add_common_fields(map(), message()) -> message().
add_common_fields(Raw, Base) ->
    M0 = maybe_add(<<"uuid">>, uuid, Raw, Base),
    maybe_add(<<"session_id">>, session_id, Raw, M0).

%%--------------------------------------------------------------------
%% Internal: Type parsing
%%--------------------------------------------------------------------

-spec parse_type(binary()) -> message_type().
parse_type(<<"text">>)             -> text;
parse_type(<<"assistant">>)        -> assistant;
parse_type(<<"tool_use">>)         -> tool_use;
parse_type(<<"tool_result">>)      -> tool_result;
parse_type(<<"system">>)           -> system;
parse_type(<<"result">>)           -> result;
parse_type(<<"error">>)            -> error;
parse_type(<<"user">>)             -> user;
parse_type(<<"control">>)          -> control;
parse_type(<<"control_request">>)  -> control_request;
parse_type(<<"control_response">>) -> control_response;
parse_type(<<"stream_event">>)     -> stream_event;
parse_type(<<"rate_limit_event">>) -> rate_limit_event;
parse_type(<<"tool_progress">>)    -> tool_progress;
parse_type(<<"tool_use_summary">>) -> tool_use_summary;
parse_type(<<"thinking">>)         -> thinking;
parse_type(<<"auth_status">>)      -> auth_status;
parse_type(<<"prompt_suggestion">>) -> prompt_suggestion;
parse_type(_Other)                 -> raw.

%%--------------------------------------------------------------------
%% Internal: Type-specific field extraction
%%--------------------------------------------------------------------

-spec add_fields(message_type(), map(), message()) -> message().
add_fields(text, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(assistant, Raw, Base) ->
    %% TS SDK: SDKAssistantMessage wraps content in a `message` object
    %% (BetaMessage). Handle both formats: top-level content array
    %% and nested message.content for protocol compatibility.
    %%
    %% SAFETY: JSON null decodes to atom `null` in OTP 27. Guard against
    %% non-map values to prevent badmap crashes on maps:get/3.
    MessageObj = case maps:get(<<"message">>, Raw, undefined) of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    ContentRaw = case maps:get(<<"content">>, Raw, undefined) of
        CL when is_list(CL) -> CL;
        _ ->
            case maps:get(<<"content">>, MessageObj, undefined) of
                ML when is_list(ML) -> ML;
                _ -> []
            end
    end,
    Blocks = agent_wire_content:parse_blocks(ContentRaw),
    M0 = Base#{content_blocks => Blocks, raw => Raw},
    M1 = maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M0),
    M2 = maybe_add(<<"error">>, error_info, Raw, M1),
    %% Extract fields from embedded BetaMessage (usage, model, stop_reason, id)
    M3 = maybe_add(<<"usage">>, usage, MessageObj, M2),
    M4 = maybe_add(<<"model">>, model, MessageObj, M3),
    M5 = maybe_add(<<"id">>, message_id, MessageObj, M4),
    case maps:get(<<"stop_reason">>, MessageObj, undefined) of
        undefined -> M5;
        SR ->
            M5#{stop_reason => SR,
                stop_reason_atom => parse_stop_reason(SR)}
    end;

add_fields(tool_use, Raw, Base) ->
    Base#{
        tool_name => maps:get(<<"tool_name">>, Raw,
                        maps:get(<<"name">>, Raw, <<>>)),
        tool_input => maps:get(<<"tool_input">>, Raw,
                         maps:get(<<"input">>, Raw, #{})),
        raw => Raw
    };

add_fields(tool_result, Raw, Base) ->
    Base#{
        tool_name => maps:get(<<"tool_name">>, Raw, <<>>),
        content => maps:get(<<"content">>, Raw, <<>>),
        raw => Raw
    };

add_fields(system, Raw, Base) ->
    %% System messages have subtypes (init, status, compact_boundary, etc.)
    %% The init subtype carries rich metadata about the session capabilities.
    M0 = Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw},
    M1 = maybe_add(<<"subtype">>, subtype, Raw, M0),
    %% Parse system init metadata into structured system_info map
    case maps:get(<<"subtype">>, Raw, undefined) of
        <<"init">> -> M1#{system_info => parse_system_init(Raw)};
        _ -> M1
    end;

add_fields(result, Raw, Base) ->
    %% CRITICAL FIX: TS SDK SDKResultSuccess uses "result" field (not "content")
    %% for the answer text. SDKResultError uses "errors" (string[]).
    %% We check "result" first, fall back to "content" for backward compat.
    Content = maps:get(<<"result">>, Raw,
                  maps:get(<<"content">>, Raw, <<>>)),
    M0 = Base#{content => Content, raw => Raw},
    enrich_result(M0, Raw);

add_fields(error, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(user, Raw, Base) ->
    M0 = Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw},
    M1 = maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M0),
    maybe_add_bool(<<"isReplay">>, is_replay, Raw, M1);

add_fields(thinking, Raw, Base) ->
    Base#{
        content => maps:get(<<"thinking">>, Raw,
                      maps:get(<<"content">>, Raw, <<>>)),
        raw => Raw
    };

add_fields(control_request, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"request_id">>, request_id, Raw, M0),
    maybe_add(<<"request">>, request, Raw, M1);

add_fields(control_response, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"request_id">>, request_id, Raw, M0),
    maybe_add(<<"response">>, response, Raw, M1);

add_fields(stream_event, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"subtype">>, subtype, Raw, M0),
    M2 = maybe_add(<<"content">>, content, Raw, M1),
    maybe_add(<<"parent_tool_use_id">>, parent_tool_use_id, Raw, M2);

add_fields(tool_progress, Raw, Base) ->
    M0 = Base#{raw => Raw},
    M1 = maybe_add(<<"content">>, content, Raw, M0),
    maybe_add(<<"tool_name">>, tool_name, Raw, M1);

add_fields(tool_use_summary, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(prompt_suggestion, Raw, Base) ->
    Base#{content => maps:get(<<"content">>, Raw, <<>>), raw => Raw};

add_fields(rate_limit_event, Raw, Base) ->
    %% TS SDK SDKRateLimitInfo: status, resetsAt, rateLimitType,
    %% utilization, overageStatus, overageResetsAt, etc.
    M0 = Base#{raw => Raw},
    Fields = [
        {<<"status">>, rate_limit_status},
        {<<"resetsAt">>, resets_at},
        {<<"rateLimitType">>, rate_limit_type},
        {<<"utilization">>, utilization},
        {<<"overageStatus">>, overage_status},
        {<<"overageResetsAt">>, overage_resets_at},
        {<<"overageDisabledReason">>, overage_disabled_reason},
        {<<"isUsingOverage">>, is_using_overage},
        {<<"surpassedThreshold">>, surpassed_threshold}
    ],
    lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, M0, Fields);

add_fields(auth_status, Raw, Base) ->
    M0 = Base#{raw => Raw},
    maybe_add(<<"content">>, content, Raw, M0);

add_fields(_Type, Raw, Base) ->
    Base#{raw => Raw}.

%%--------------------------------------------------------------------
%% Internal: Result enrichment
%%--------------------------------------------------------------------

%% @doc Enrich a result message with all protocol fields from the
%%      TS SDK v0.2.66 SDKResultSuccess/SDKResultError types.
%%      Only includes fields actually present in the raw message.
-spec enrich_result(message(), map()) -> message().
enrich_result(M0, Raw) ->
    Fields = [
        {<<"duration_ms">>, duration_ms},
        {<<"duration_api_ms">>, duration_api_ms},
        {<<"num_turns">>, num_turns},
        {<<"session_id">>, session_id},
        {<<"stop_reason">>, stop_reason},
        {<<"usage">>, usage},
        {<<"total_cost_usd">>, total_cost_usd},
        {<<"is_error">>, is_error},
        {<<"subtype">>, subtype},
        {<<"modelUsage">>, model_usage},
        {<<"permission_denials">>, permission_denials},
        {<<"errors">>, errors},
        {<<"structured_output">>, structured_output},
        {<<"fast_mode_state">>, fast_mode_state}
    ],
    M1 = lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, M0, Fields),
    %% Add parsed stop_reason atom if binary stop_reason is present
    case maps:find(stop_reason, M1) of
        {ok, SR} when is_binary(SR) ->
            M1#{stop_reason_atom => parse_stop_reason(SR)};
        _ ->
            M1
    end.

%%--------------------------------------------------------------------
%% Internal: System init parsing
%%--------------------------------------------------------------------

%% @doc Parse a system init message into a structured map of session
%%      capabilities. The TS SDK SDKSystemMessage (subtype: init) includes
%%      tools, model, MCP servers, slash commands, skills, plugins, etc.
-spec parse_system_init(map()) -> map().
parse_system_init(Raw) ->
    Fields = [
        {<<"tools">>, tools},
        {<<"model">>, model},
        {<<"mcp_servers">>, mcp_servers},
        {<<"slash_commands">>, slash_commands},
        {<<"skills">>, skills},
        {<<"plugins">>, plugins},
        {<<"agents">>, agents},
        {<<"permissionMode">>, permission_mode},
        {<<"claude_code_version">>, claude_code_version},
        {<<"cwd">>, cwd},
        {<<"apiKeySource">>, api_key_source},
        {<<"betas">>, betas},
        {<<"output_style">>, output_style},
        {<<"fast_mode_state">>, fast_mode_state}
    ],
    lists:foldl(fun({BinKey, AtomKey}, Acc) ->
        case maps:find(BinKey, Raw) of
            {ok, V} -> Acc#{AtomKey => V};
            error   -> Acc
        end
    end, #{}, Fields).

%%--------------------------------------------------------------------
%% Internal: Field helpers
%%--------------------------------------------------------------------

%% @doc Conditionally add a field to the message map if present in raw.
-spec maybe_add(binary(), atom(), map(), message()) -> message().
maybe_add(BinKey, AtomKey, Raw, Msg) ->
    case maps:find(BinKey, Raw) of
        {ok, V} -> Msg#{AtomKey => V};
        error   -> Msg
    end.

%% @doc Conditionally add a boolean field, treating JSON null as absent.
-spec maybe_add_bool(binary(), atom(), map(), message()) -> message().
maybe_add_bool(BinKey, AtomKey, Raw, Msg) ->
    case maps:find(BinKey, Raw) of
        {ok, true}  -> Msg#{AtomKey => true};
        {ok, false} -> Msg#{AtomKey => false};
        _           -> Msg
    end.

%%--------------------------------------------------------------------
%% Generic Message Collection
%%--------------------------------------------------------------------

%% Function that pulls the next message from a session.
%% Signature: fun(Session :: pid(), Ref :: reference(), Timeout :: timeout())
%%   -> {ok, message()} | {error, term()}.
-type receive_fun() :: fun((pid(), reference(), timeout()) ->
    {ok, message()} | {error, term()}).

%% Predicate that determines if a message terminates collection.
%% Returns `true' for messages that should halt the loop (included in
%% the result), `false' for messages that should continue collection.
-type terminal_pred() :: fun((message()) -> boolean()).

%% @doc Collect all messages from a session using the default terminal
%%      predicate: `result' and `error' messages halt the loop.
%%
%%      `ReceiveFun' is the adapter-specific function that pulls the next
%%      message (e.g. `gen_statem:call(Session, {receive_message, Ref}, T)').
%%
%%      Returns `{ok, Messages}' in order, or `{error, Reason}' on
%%      timeout or transport failure.
%%
%% @see collect_messages/5
-spec collect_messages(pid(), reference(), integer(), receive_fun()) ->
    {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun) ->
    collect_messages(Session, Ref, Deadline, ReceiveFun,
        fun default_terminal/1).

%% @doc Collect all messages with a custom terminal predicate.
%%
%%      The predicate receives each message and returns `true' if
%%      collection should stop (the message is included in the result).
%%      This allows adapters like Copilot — where only `is_error: true'
%%      errors are terminal — to customize halt behavior.
-spec collect_messages(pid(), reference(), integer(), receive_fun(),
    terminal_pred()) -> {ok, [message()]} | {error, term()}.
collect_messages(Session, Ref, Deadline, ReceiveFun, IsTerminal) ->
    collect_loop(Session, Ref, Deadline, ReceiveFun, IsTerminal, []).

%% @private
-spec collect_loop(pid(), reference(), integer(), receive_fun(),
    terminal_pred(), [message()]) -> {ok, [message()]} | {error, term()}.
collect_loop(Session, Ref, Deadline, ReceiveFun, IsTerminal, Acc) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true ->
            {error, timeout};
        false ->
            case ReceiveFun(Session, Ref, Remaining) of
                {ok, Msg} ->
                    case IsTerminal(Msg) of
                        true ->
                            {ok, lists:reverse([Msg | Acc])};
                        false ->
                            collect_loop(Session, Ref, Deadline,
                                ReceiveFun, IsTerminal, [Msg | Acc])
                    end;
                {error, complete} ->
                    {ok, lists:reverse(Acc)};
                {error, _} = Err ->
                    Err
            end
    end.

%% @doc Default terminal predicate: `result' and `error' messages halt.
-spec default_terminal(message()) -> boolean().
default_terminal(#{type := result}) -> true;
default_terminal(#{type := error}) -> true;
default_terminal(_) -> false.
