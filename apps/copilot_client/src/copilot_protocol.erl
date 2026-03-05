%%%-------------------------------------------------------------------
%%% @doc Copilot session event normalization and wire format builders.
%%%
%%% Maps Copilot session events (from session.event notifications)
%%% to agent_wire:message() types, and builds JSON-RPC params for
%%% outgoing Copilot RPC methods.
%%%
%%% Copilot uses a rich event model with typed session events:
%%%   assistant.message, assistant.message_delta, session.idle,
%%%   tool.executing, tool.completed, permission.request, etc.
%%%
%%% Pure functions — no processes, no state.
%%% @end
%%%-------------------------------------------------------------------
-module(copilot_protocol).

-export([
    %% Event normalization
    normalize_event/1,
    %% Wire format builders
    build_session_create_params/1,
    build_session_resume_params/2,
    build_session_send_params/3,
    build_tool_result/2,
    build_permission_result/1,
    build_hook_result/1,
    build_user_input_result/1,
    %% JSON-RPC 2.0 encoding (with "jsonrpc" field — Copilot includes it)
    encode_request/3,
    encode_response/2,
    encode_error_response/3,
    encode_error_response/4,
    %% CLI command building
    build_cli_args/1,
    build_env/1,
    %% SDK protocol version
    sdk_protocol_version/0
]).

%% Normalization covers many event types — the catch-all is intentionally broad.
-dialyzer({nowarn_function, [normalize_event/1]}).
-dialyzer({no_underspecs, [
    build_session_create_params/1,
    build_session_resume_params/2,
    build_session_send_params/3,
    build_tool_result/2,
    build_permission_result/1,
    build_hook_result/1,
    build_user_input_result/1,
    build_system_message_config/1,
    build_provider_config/1,
    build_mcp_servers_config/1,
    build_custom_agents_config/1,
    build_infinite_sessions_config/1,
    maybe_put/3,
    maybe_put_list/3,
    maybe_put_opt/4,
    build_cli_args/1,
    build_env/1
]}).

%%--------------------------------------------------------------------
%% Constants
%%--------------------------------------------------------------------

%% SDK protocol version — must match Copilot CLI expectations.
%% Corresponds to Python SDK's get_sdk_protocol_version().
-define(SDK_PROTOCOL_VERSION, 3).
-define(SDK_VERSION, "0.1.0").

%%====================================================================
%% Event Normalization
%%====================================================================

%% @doc Normalize a Copilot session event into an agent_wire:message().
%%      The event map contains a "type" field and a "data" sub-map.
-spec normalize_event(map()) -> agent_wire:message().

%% --- Assistant Messages ---

%% Complete assistant message
normalize_event(#{<<"type">> := <<"assistant.message">>,
                   <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    Base = #{type => assistant, content => Content},
    maybe_add_message_fields(Base, Data);

%% Streaming assistant text delta
normalize_event(#{<<"type">> := <<"assistant.message_delta">>,
                   <<"data">> := Data}) ->
    DeltaContent = maps:get(<<"deltaContent">>, Data,
                    maps:get(<<"delta_content">>, Data, <<>>)),
    #{type => text, content => DeltaContent};

%% Reasoning / thinking content
normalize_event(#{<<"type">> := <<"assistant.reasoning">>,
                   <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    #{type => thinking, content => Content};

%% Streaming reasoning delta
normalize_event(#{<<"type">> := <<"assistant.reasoning_delta">>,
                   <<"data">> := Data}) ->
    DeltaContent = maps:get(<<"deltaContent">>, Data,
                    maps:get(<<"delta_content">>, Data, <<>>)),
    #{type => thinking, content => DeltaContent};

%% --- Tool Events ---

%% Tool execution started
normalize_event(#{<<"type">> := <<"tool.executing">>,
                   <<"data">> := Data}) ->
    ToolName = maps:get(<<"toolName">>, Data,
                maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ToolInput = maps:get(<<"arguments">>, Data,
                 maps:get(<<"toolInput">>, Data, #{})),
    Base = #{type => tool_use, tool_name => ToolName, tool_input => ToolInput},
    maybe_add_tool_id(Base, Data);

%% Tool completed successfully
normalize_event(#{<<"type">> := <<"tool.completed">>,
                   <<"data">> := Data}) ->
    ToolName = maps:get(<<"toolName">>, Data,
                maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    Content = maps:get(<<"output">>, Data,
               maps:get(<<"content">>, Data, <<>>)),
    Base = #{type => tool_result, tool_name => ToolName, content => Content},
    maybe_add_tool_id(Base, Data);

%% Tool errored
normalize_event(#{<<"type">> := <<"tool.errored">>,
                   <<"data">> := Data}) ->
    ToolName = maps:get(<<"toolName">>, Data,
                maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ErrorMsg = maps:get(<<"error">>, Data,
                maps:get(<<"message">>, Data, <<"tool error">>)),
    Base = #{type => error, content => ErrorMsg,
             error_type => tool_error, tool_name => ToolName},
    maybe_add_tool_id(Base, Data);

%% Agent-level tool call
normalize_event(#{<<"type">> := <<"agent.toolCall">>,
                   <<"data">> := Data}) ->
    ToolName = maps:get(<<"toolName">>, Data,
                maps:get(<<"tool_name">>, Data, <<"unknown">>)),
    ToolInput = maps:get(<<"arguments">>, Data,
                 maps:get(<<"toolInput">>, Data, #{})),
    Base = #{type => tool_use, tool_name => ToolName, tool_input => ToolInput},
    maybe_add_tool_id(Base, Data);

%% --- Session Lifecycle ---

%% Session idle (query complete)
normalize_event(#{<<"type">> := <<"session.idle">>} = Event) ->
    Data = maps:get(<<"data">>, Event, #{}),
    Base = #{type => result},
    maybe_add_usage(Base, Data);

%% Session error
normalize_event(#{<<"type">> := <<"session.error">>,
                   <<"data">> := Data}) ->
    Message = maps:get(<<"message">>, Data,
               maps:get(<<"error">>, Data, <<"session error">>)),
    #{type => error, content => Message, error_type => session_error};

%% Session resume
normalize_event(#{<<"type">> := <<"session.resume">>,
                   <<"data">> := Data}) ->
    #{type => system, subtype => resume, content => Data};

%% --- Permission Events ---

%% Permission request (as notification/event)
normalize_event(#{<<"type">> := <<"permission.request">>,
                   <<"data">> := Data}) ->
    Kind = maps:get(<<"kind">>, Data, <<"unknown">>),
    #{type => control_request, content => Data,
      subtype => permission_request, permission_kind => Kind};

%% Permission resolved
normalize_event(#{<<"type">> := <<"permission.resolved">>,
                   <<"data">> := Data}) ->
    #{type => control_response, content => Data,
      subtype => permission_resolved};

%% --- Compaction Events ---

normalize_event(#{<<"type">> := <<"compaction.started">>,
                   <<"data">> := Data}) ->
    #{type => system, subtype => compaction_started, content => Data};

normalize_event(#{<<"type">> := <<"compaction.completed">>,
                   <<"data">> := Data}) ->
    #{type => system, subtype => compaction_completed, content => Data};

%% --- Plan Events ---

normalize_event(#{<<"type">> := <<"plan.update">>,
                   <<"data">> := Data}) ->
    #{type => system, subtype => plan_update, content => Data};

%% --- User Message Echo ---

normalize_event(#{<<"type">> := <<"user.message">>,
                   <<"data">> := Data}) ->
    Content = maps:get(<<"content">>, Data, <<>>),
    #{type => user, content => Content};

%% --- Catch-all for unknown event types ---

normalize_event(#{<<"type">> := Type} = Event) ->
    Data = maps:get(<<"data">>, Event, #{}),
    #{type => raw, content => Data, subtype => Type};

%% Completely unknown structure
normalize_event(Event) when is_map(Event) ->
    #{type => raw, content => Event}.

%%====================================================================
%% Wire Format Builders
%%====================================================================

%% @doc Build params for session.create RPC call.
-spec build_session_create_params(map()) -> map().
build_session_create_params(Opts) ->
    Params = #{},
    P1 = maybe_put(<<"sessionId">>, maps:get(session_id, Opts, undefined), Params),
    P2 = maybe_put(<<"model">>, maps:get(model, Opts, undefined), P1),
    P3 = maybe_put(<<"reasoningEffort">>, maps:get(reasoning_effort, Opts, undefined), P2),
    P4 = maybe_put(<<"workingDirectory">>, maps:get(work_dir, Opts,
                     maps:get(working_directory, Opts, undefined)), P3),
    P5 = maybe_put(<<"clientName">>, maps:get(client_name, Opts, undefined), P4),
    P6 = maybe_put(<<"streaming">>, maps:get(streaming, Opts, undefined), P5),
    P7 = maybe_put(<<"configDir">>, maps:get(config_dir, Opts, undefined), P6),
    P8 = maybe_put_list(<<"availableTools">>, maps:get(available_tools, Opts, undefined), P7),
    P9 = maybe_put_list(<<"excludedTools">>, maps:get(excluded_tools, Opts, undefined), P8),
    P10 = maybe_put_list(<<"skillDirectories">>, maps:get(skill_directories, Opts, undefined), P9),
    P11 = maybe_put_list(<<"disabledSkills">>, maps:get(disabled_skills, Opts, undefined), P10),
    P12 = maybe_put_opt(<<"systemMessage">>, maps:get(system_message, Opts, undefined),
                         fun build_system_message_config/1, P11),
    P13 = maybe_put_opt(<<"provider">>, maps:get(provider, Opts, undefined),
                          fun build_provider_config/1, P12),
    P14 = maybe_put_opt(<<"mcpServers">>, maps:get(mcp_servers, Opts, undefined),
                          fun build_mcp_servers_config/1, P13),
    P15 = maybe_put_opt(<<"customAgents">>, maps:get(custom_agents, Opts, undefined),
                          fun build_custom_agents_config/1, P14),
    P16 = maybe_put_opt(<<"infiniteSessions">>,
                          maps:get(infinite_sessions, Opts, undefined),
                          fun build_infinite_sessions_config/1, P15),
    P17 = maybe_put(<<"outputFormat">>,
                     maps:get(output_format, Opts, undefined), P16),
    %% SDK tools are registered via server-initiated tool.call requests,
    %% but tool definitions need to be sent in session.create
    maybe_put_opt(<<"tools">>, maps:get(sdk_tools, Opts, undefined),
                   fun build_tool_definitions/1, P17).

%% @doc Build params for session.resume RPC call.
-spec build_session_resume_params(binary(), map()) -> map().
build_session_resume_params(SessionId, Opts) ->
    Base = build_session_create_params(Opts),
    P1 = Base#{<<"sessionId">> => SessionId},
    maybe_put(<<"disableResume">>, maps:get(disable_resume, Opts, undefined), P1).

%% @doc Build params for session.send RPC call.
-spec build_session_send_params(binary(), binary(), map()) -> map().
build_session_send_params(SessionId, Prompt, Params) ->
    Base = #{<<"sessionId">> => SessionId, <<"prompt">> => Prompt},
    P1 = maybe_put_list(<<"attachments">>,
                         maps:get(attachments, Params, undefined), Base),
    P2 = maybe_put(<<"mode">>, maps:get(mode, Params, undefined), P1),
    maybe_put(<<"outputFormat">>, maps:get(output_format, Params, undefined), P2).

%% @doc Build response for a tool.call server request.
-spec build_tool_result(map(), map()) -> map().
build_tool_result(Result, _Context) ->
    Base = #{},
    P1 = maybe_put(<<"textResultForLlm">>,
                    maps:get(text_result, Result,
                      maps:get(<<"textResultForLlm">>, Result, undefined)), Base),
    P2 = maybe_put(<<"resultType">>,
                    maps:get(result_type, Result,
                      maps:get(<<"resultType">>, Result, <<"success">>)), P1),
    P3 = maybe_put(<<"error">>,
                    maps:get(error, Result,
                      maps:get(<<"error">>, Result, undefined)), P2),
    maybe_put(<<"sessionLog">>,
              maps:get(session_log, Result,
                maps:get(<<"sessionLog">>, Result, undefined)), P3).

%% @doc Build response for a permission.request server request.
-spec build_permission_result(agent_wire:permission_result() | map()) -> map().
build_permission_result({allow, _}) ->
    #{<<"result">> => #{<<"kind">> => <<"approved">>}};
build_permission_result({allow, _, _}) ->
    #{<<"result">> => #{<<"kind">> => <<"approved">>}};
build_permission_result({deny, _Reason}) ->
    #{<<"result">> => #{<<"kind">> => <<"denied-interactively-by-user">>}};
build_permission_result(#{<<"kind">> := _} = Result) ->
    #{<<"result">> => Result};
build_permission_result(_) ->
    #{<<"result">> => #{<<"kind">> =>
        <<"denied-no-approval-rule-and-could-not-request-from-user">>}}.

%% @doc Build response for a hooks.invoke server request.
-spec build_hook_result(term()) -> map().
build_hook_result(undefined) -> #{};
build_hook_result(Result) when is_map(Result) -> Result;
build_hook_result(_) -> #{}.

%% @doc Build response for a user_input.request server request.
-spec build_user_input_result(map()) -> map().
build_user_input_result(#{answer := Answer} = Result) ->
    WasFreeform = maps:get(was_freeform, Result,
                    maps:get(wasFreeform, Result, false)),
    #{<<"answer">> => ensure_binary(Answer),
      <<"wasFreeform">> => WasFreeform};
build_user_input_result(#{<<"answer">> := _} = Result) ->
    Result;
build_user_input_result(_) ->
    #{<<"answer">> => <<>>, <<"wasFreeform">> => true}.

%%====================================================================
%% JSON-RPC 2.0 Encoding (with "jsonrpc" field)
%%====================================================================

%% @doc Encode a JSON-RPC 2.0 request.
%%      Unlike Codex, Copilot includes "jsonrpc":"2.0" on the wire.
-spec encode_request(binary(), binary(), map() | undefined) -> map().
encode_request(Id, Method, undefined) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => Method,
      <<"params">> => #{}};
encode_request(Id, Method, Params) when is_map(Params) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => Method,
      <<"params">> => Params}.

%% @doc Encode a JSON-RPC 2.0 success response.
-spec encode_response(binary() | integer(), term()) -> map().
encode_response(Id, Result) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => Result}.

%% @doc Encode a JSON-RPC 2.0 error response (without data).
-spec encode_error_response(binary() | integer(), integer(), binary()) -> map().
encode_error_response(Id, Code, Message) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message}}.

%% @doc Encode a JSON-RPC 2.0 error response (with data).
-spec encode_error_response(binary() | integer(), integer(), binary(), term()) -> map().
encode_error_response(Id, Code, Message, Data) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
      <<"error">> => #{<<"code">> => Code, <<"message">> => Message,
                       <<"data">> => Data}}.

%%====================================================================
%% CLI Command Building
%%====================================================================

%% @doc Build CLI arguments for starting the Copilot server process.
-spec build_cli_args(map()) -> [string()].
build_cli_args(Opts) ->
    Base = ["server", "--stdio"],
    WithLogLevel = case maps:get(log_level, Opts, undefined) of
        undefined -> Base;
        Level when is_binary(Level) ->
            Base ++ ["--log-level", binary_to_list(Level)];
        Level when is_atom(Level) ->
            Base ++ ["--log-level", atom_to_list(Level)];
        Level when is_list(Level) ->
            Base ++ ["--log-level", Level]
    end,
    WithProtocol = WithLogLevel ++ [
        "--sdk-protocol-version", integer_to_list(?SDK_PROTOCOL_VERSION)
    ],
    %% Prepend user CLI args (before SDK-managed args, matching Python SDK)
    case maps:get(cli_args, Opts, undefined) of
        undefined -> WithProtocol;
        UserArgs when is_list(UserArgs) ->
            %% Insert after "server" but before other flags
            ["server" | UserExtra] = WithProtocol,
            ExtraStrings = [ensure_list(A) || A <- UserArgs],
            ["server" | ExtraStrings ++ UserExtra]
    end.

%% @doc Build environment variables for the CLI process.
-spec build_env(map()) -> [{string(), string()}].
build_env(Opts) ->
    BaseEnv = [
        {"COPILOT_SDK_VERSION", "beam-" ++ ?SDK_VERSION},
        {"NO_COLOR", "1"}
    ],
    TokenEnv = case maps:get(github_token, Opts, undefined) of
        undefined -> [];
        Token when is_binary(Token) ->
            [{"GITHUB_TOKEN", binary_to_list(Token)}];
        Token when is_list(Token) ->
            [{"GITHUB_TOKEN", Token}]
    end,
    UserEnv = case maps:get(env, Opts, undefined) of
        undefined -> [];
        Env when is_list(Env) ->
            [{ensure_list(K), ensure_list(V)} || {K, V} <- Env];
        Env when is_map(Env) ->
            [{ensure_list(K), ensure_list(V)} || {K, V} <- maps:to_list(Env)]
    end,
    BaseEnv ++ TokenEnv ++ UserEnv.

%% @doc Return the SDK protocol version number.
-spec sdk_protocol_version() -> pos_integer().
sdk_protocol_version() -> ?SDK_PROTOCOL_VERSION.

%%====================================================================
%% Internal Helpers
%%====================================================================

%% @private Add optional fields from assistant message data.
-spec maybe_add_message_fields(map(), map()) -> map().
maybe_add_message_fields(Base, Data) ->
    Fields = [
        {message_id, <<"messageId">>},
        {model, <<"model">>},
        {role, <<"role">>}
    ],
    lists:foldl(fun({Key, WireKey}, Acc) ->
        case maps:get(WireKey, Data, undefined) of
            undefined -> Acc;
            Val -> Acc#{Key => Val}
        end
    end, Base, Fields).

%% @private Add tool_use_id if present.
-spec maybe_add_tool_id(map(), map()) -> map().
maybe_add_tool_id(Base, Data) ->
    case maps:get(<<"toolCallId">>, Data,
           maps:get(<<"tool_call_id">>, Data, undefined)) of
        undefined -> Base;
        ToolId -> Base#{tool_use_id => ToolId}
    end.

%% @private Add usage info if present in data.
-spec maybe_add_usage(map(), map()) -> map().
maybe_add_usage(Base, Data) ->
    case maps:get(<<"usage">>, Data, undefined) of
        undefined -> Base;
        Usage when is_map(Usage) -> Base#{usage => Usage}
    end.

%% @private Conditionally add a key-value pair to a map.
-spec maybe_put(binary(), term(), map()) -> map().
maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => Value}.

%% @private Conditionally add a list value (skip if undefined or empty).
-spec maybe_put_list(binary(), term(), map()) -> map().
maybe_put_list(_Key, undefined, Map) -> Map;
maybe_put_list(_Key, [], Map) -> Map;
maybe_put_list(Key, List, Map) when is_list(List) -> Map#{Key => List}.

%% @private Conditionally apply a transform and add to map.
-spec maybe_put_opt(binary(), term(), fun((term()) -> term()), map()) -> map().
maybe_put_opt(_Key, undefined, _Fun, Map) -> Map;
maybe_put_opt(Key, Value, Fun, Map) -> Map#{Key => Fun(Value)}.

%% @private Build system message configuration for wire format.
-spec build_system_message_config(map() | binary()) -> map().
build_system_message_config(Config) when is_binary(Config) ->
    #{<<"mode">> => <<"append">>, <<"content">> => Config};
build_system_message_config(#{mode := <<"replace">>, content := Content}) ->
    #{<<"mode">> => <<"replace">>, <<"content">> => Content};
build_system_message_config(#{mode := replace, content := Content}) ->
    #{<<"mode">> => <<"replace">>, <<"content">> => Content};
build_system_message_config(#{content := Content}) ->
    #{<<"mode">> => <<"append">>, <<"content">> => Content};
build_system_message_config(Config) when is_map(Config) ->
    Config.

%% @private Build provider configuration for wire format.
-spec build_provider_config(map()) -> map().
build_provider_config(Config) when is_map(Config) ->
    Mapping = [
        {type, <<"type">>},
        {wire_api, <<"wireApi">>},
        {base_url, <<"baseUrl">>},
        {api_key, <<"apiKey">>},
        {bearer_token, <<"bearerToken">>}
    ],
    maps:fold(fun(K, V, Acc) ->
        case lists:keyfind(K, 1, Mapping) of
            {K, WireKey} -> Acc#{WireKey => ensure_binary(V)};
            false -> Acc
        end
    end, #{}, Config).

%% @private Build MCP servers configuration for wire format.
-spec build_mcp_servers_config(map()) -> map().
build_mcp_servers_config(Config) when is_map(Config) ->
    Config.

%% @private Build custom agents configuration for wire format.
-spec build_custom_agents_config(list()) -> list().
build_custom_agents_config(Agents) when is_list(Agents) ->
    Agents.

%% @private Build infinite sessions configuration for wire format.
-spec build_infinite_sessions_config(map()) -> map().
build_infinite_sessions_config(Config) when is_map(Config) ->
    Config.

%% @private Build tool definitions from SDK tool specs.
-spec build_tool_definitions(list()) -> list().
build_tool_definitions(Tools) when is_list(Tools) ->
    [build_tool_def(T) || T <- Tools].

-spec build_tool_def(map()) -> map().
build_tool_def(#{name := Name, description := Desc} = Tool) ->
    Base = #{<<"name">> => ensure_binary(Name),
             <<"description">> => ensure_binary(Desc)},
    case maps:get(parameters, Tool, undefined) of
        undefined -> Base;
        Schema -> Base#{<<"parameters">> => Schema}
    end;
build_tool_def(#{name := Name} = Tool) ->
    %% Tool with name but no description — build minimal definition.
    %% Always strip handler (it's a fun for local dispatch, not for wire).
    Base = #{<<"name">> => ensure_binary(Name)},
    P1 = maybe_put(<<"description">>,
                    maps:get(description, Tool, undefined), Base),
    case maps:get(parameters, Tool, undefined) of
        undefined -> P1;
        Schema -> P1#{<<"parameters">> => Schema}
    end;
build_tool_def(Tool) when is_map(Tool) ->
    %% Unknown structure — strip handler key to avoid encoding funs
    maps:without([handler], Tool).

%% @private Ensure a value is a binary string.
-spec ensure_binary(term()) -> binary().
ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V);
ensure_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% @private Ensure a value is a list string.
-spec ensure_list(term()) -> string().
ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V);
ensure_list(V) when is_atom(V) -> atom_to_list(V);
ensure_list(V) -> lists:flatten(io_lib:format("~p", [V])).
