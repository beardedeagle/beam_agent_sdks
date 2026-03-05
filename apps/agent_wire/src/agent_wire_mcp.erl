%%%-------------------------------------------------------------------
%%% @doc In-process MCP server support for the BEAM Agent SDK.
%%%
%%% Enables users to define custom tools as Erlang functions that
%%% Claude can call in-process via the mcp_message control request
%%% protocol. Cross-referenced against TS SDK v0.2.66
%%% createSdkMcpServer() and Python SDK create_sdk_mcp_server().
%%%
%%% Usage:
%%%   Tool = agent_wire_mcp:tool(<<"greet">>, <<"Greet a user">>,
%%%       #{<<"type">> => <<"object">>,
%%%         <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}},
%%%       fun(Input) ->
%%%           Name = maps:get(<<"name">>, Input, <<"world">>),
%%%           {ok, [#{type => text, text => <<"Hello, ", Name/binary, "!">>}]}
%%%       end),
%%%   Server = agent_wire_mcp:server(<<"my-tools">>, [Tool]),
%%%   %% Pass to session:
%%%   claude_agent_session:start_link(#{sdk_mcp_servers => [Server]})
%%% @end
%%%-------------------------------------------------------------------
-module(agent_wire_mcp).

-export([
    %% Constructors
    tool/4,
    server/2,
    server/3,
    %% Registry management
    new_registry/0,
    register_server/2,
    server_names/1,
    %% CLI integration
    servers_for_cli/1,
    servers_for_init/1,
    %% JSON-RPC dispatch
    handle_mcp_message/3,
    handle_mcp_message/4,
    %% Flat tool dispatch (no server context)
    call_tool_by_name/3,
    call_tool_by_name/4,
    all_tool_definitions/1,
    %% Convenience: build registry from session opts
    build_registry/1
]).

-export_type([
    tool_handler/0,
    content_result/0,
    tool_def/0,
    sdk_mcp_server/0,
    mcp_registry/0
]).

%% new_registry/0 returns #{} typed as mcp_registry() (intentional supertype).
%% format_content/1 returns specific key binaries, spec uses binary() (intentional).
-dialyzer({nowarn_function, [new_registry/0, format_content/1]}).

%%--------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------

%% Handler function invoked when Claude calls an in-process tool.
%% Receives the tool arguments map, returns content results or error.
-type tool_handler() :: fun((map()) ->
    {ok, [content_result()]} | {error, binary()}).

%% Content result from a tool handler.
-type content_result() :: #{type := text, text := binary()}
                        | #{type := image, data := binary(),
                            mime_type := binary()}.

%% Tool definition with name, description, JSON schema, and handler.
-type tool_def() :: #{
    name := binary(),
    description := binary(),
    input_schema := map(),
    handler := tool_handler()
}.

%% An SDK MCP server grouping one or more tools under a name.
-type sdk_mcp_server() :: #{
    name := binary(),
    version => binary(),
    tools := [tool_def()]
}.

%% Registry mapping server names to their definitions.
-type mcp_registry() :: #{binary() => sdk_mcp_server()}.

%% Default tool handler timeout (30 seconds).
-define(DEFAULT_HANDLER_TIMEOUT, 30000).

%%--------------------------------------------------------------------
%% Constructors
%%--------------------------------------------------------------------

%% @doc Create a tool definition.
-spec tool(binary(), binary(), map(), tool_handler()) -> tool_def().
tool(Name, Description, InputSchema, Handler)
  when is_binary(Name), is_binary(Description),
       is_map(InputSchema), is_function(Handler, 1) ->
    #{name => Name, description => Description,
      input_schema => InputSchema, handler => Handler}.

%% @doc Create an SDK MCP server with default version "1.0.0".
-spec server(binary(), [tool_def()]) -> sdk_mcp_server().
server(Name, Tools) ->
    server(Name, Tools, <<"1.0.0">>).

%% @doc Create an SDK MCP server with explicit version.
-spec server(binary(), [tool_def()], binary()) -> sdk_mcp_server().
server(Name, Tools, Version)
  when is_binary(Name), is_list(Tools), is_binary(Version) ->
    #{name => Name, tools => Tools, version => Version}.

%%--------------------------------------------------------------------
%% Registry Management
%%--------------------------------------------------------------------

%% @doc Create an empty MCP server registry.
-spec new_registry() -> mcp_registry().
new_registry() -> #{}.

%% @doc Register an SDK MCP server in the registry.
-spec register_server(sdk_mcp_server(), mcp_registry()) -> mcp_registry().
register_server(#{name := Name} = Server, Registry) ->
    Registry#{Name => Server}.

%% @doc Get the list of server names in the registry.
-spec server_names(mcp_registry()) -> [binary()].
server_names(Registry) ->
    maps:keys(Registry).

%%--------------------------------------------------------------------
%% CLI Integration
%%--------------------------------------------------------------------

%% @doc Build the --mcp-config JSON map for CLI invocation.
%%      Produces the wire format expected by Claude Code CLI:
%%      #{<<"mcpServers">> => #{Name => #{<<"type">> => <<"sdk">>,
%%                                        <<"name">> => Name}}}
-spec servers_for_cli(mcp_registry()) -> map().
servers_for_cli(Registry) ->
    ServerConfigs = maps:fold(fun(Name, _Server, Acc) ->
        Acc#{Name => #{<<"type">> => <<"sdk">>, <<"name">> => Name}}
    end, #{}, Registry),
    #{<<"mcpServers">> => ServerConfigs}.

%% @doc Build the sdkMcpServers list for the initialize control_request.
-spec servers_for_init(mcp_registry()) -> [binary()].
servers_for_init(Registry) ->
    maps:keys(Registry).

%%--------------------------------------------------------------------
%% JSON-RPC Dispatch
%%--------------------------------------------------------------------

%% @doc Handle an MCP JSON-RPC message for a named server.
%%      Uses default handler timeout of 30 seconds.
%% @see handle_mcp_message/4
-spec handle_mcp_message(binary(), map(), mcp_registry()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry) ->
    handle_mcp_message(ServerName, Message, Registry, #{}).

%% @doc Handle an MCP JSON-RPC message for a named server with options.
%%      Dispatches to the appropriate handler based on the method.
%%
%%      Options:
%%        - `handler_timeout` — timeout in ms for tool handlers (default: 30000)
%%
%%      Supported methods:
%%        - "initialize" — capabilities + server info
%%        - "notifications/initialized" — no-op acknowledgment
%%        - "tools/list" — tool definitions in MCP format
%%        - "tools/call" — execute handler, wrap result
%%        - unknown — JSON-RPC -32601 error
-spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ->
    {ok, map()} | {error, binary()}.
handle_mcp_message(ServerName, Message, Registry, Opts) ->
    case maps:find(ServerName, Registry) of
        {ok, Server} ->
            Timeout = maps:get(handler_timeout, Opts, ?DEFAULT_HANDLER_TIMEOUT),
            dispatch_jsonrpc(Message, Server, Timeout);
        error ->
            {error, <<"Unknown MCP server: ", ServerName/binary>>}
    end.

%%--------------------------------------------------------------------
%% Flat Tool Dispatch
%%--------------------------------------------------------------------

%% @doc Call a tool by name, searching across all servers in the registry.
%%      Uses default handler timeout of 30 seconds.
%% @see call_tool_by_name/4
-spec call_tool_by_name(binary(), map(), mcp_registry()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry) ->
    call_tool_by_name(ToolName, Arguments, Registry, #{}).

%% @doc Call a tool by name with options.
%%      Searches across all servers in the registry.
%%      Used by adapters that receive flat tool calls without server context
%%      (e.g. Copilot `tool.call`, Codex MCP dispatch).
%%
%%      Options:
%%        - `handler_timeout` — timeout in ms for tool handlers (default: 30000)
-spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ->
    {ok, [content_result()]} | {error, binary()}.
call_tool_by_name(ToolName, Arguments, Registry, Opts) ->
    Timeout = maps:get(handler_timeout, Opts, ?DEFAULT_HANDLER_TIMEOUT),
    case find_tool_in_registry(ToolName, Registry) of
        {ok, #{handler := Handler}} ->
            call_handler(Handler, Arguments, Timeout);
        error ->
            {error, <<"Unknown tool: ", ToolName/binary>>}
    end.

%% @doc Get all tool definitions from the registry, flattened across servers.
%%      Useful for advertising available tools during session setup.
-spec all_tool_definitions(mcp_registry()) -> [tool_def()].
all_tool_definitions(Registry) ->
    lists:append(maps:fold(fun(_Name, #{tools := Tools}, Acc) ->
        [Tools | Acc]
    end, [], Registry)).

%%--------------------------------------------------------------------
%% Convenience: Build Registry from Session Opts
%%--------------------------------------------------------------------

%% @doc Build an MCP registry from a list of SDK MCP server definitions.
%%      Returns `undefined' when no servers are configured (empty list
%%      or `undefined'). Used by all adapter session modules during init.
-spec build_registry([sdk_mcp_server()] | undefined) ->
    mcp_registry() | undefined.
build_registry(undefined) -> undefined;
build_registry([]) -> undefined;
build_registry(Servers) when is_list(Servers) ->
    lists:foldl(fun(S, Reg) ->
        register_server(S, Reg)
    end, new_registry(), Servers).

%%--------------------------------------------------------------------
%% Internal: JSON-RPC Method Dispatch
%%--------------------------------------------------------------------

-spec dispatch_jsonrpc(map(), sdk_mcp_server(), pos_integer()) -> {ok, map()}.
dispatch_jsonrpc(#{<<"method">> := <<"initialize">>} = Msg, Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Version = maps:get(version, Server, <<"1.0.0">>),
    Name = maps:get(name, Server),
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{
            <<"protocolVersion">> => <<"2024-11-05">>,
            <<"capabilities">> => #{<<"tools">> => #{}},
            <<"serverInfo">> => #{
                <<"name">> => Name,
                <<"version">> => Version
            }
        }
    }};

dispatch_jsonrpc(#{<<"method">> := <<"notifications/initialized">>}, _Server, _Timeout) ->
    %% No response needed for notifications, return empty ack
    {ok, #{}};

dispatch_jsonrpc(#{<<"method">> := <<"tools/list">>} = Msg, Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Tools = maps:get(tools, Server, []),
    ToolDefs = [tool_to_mcp_format(T) || T <- Tools],
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{<<"tools">> => ToolDefs}
    }};

dispatch_jsonrpc(#{<<"method">> := <<"tools/call">>} = Msg, Server, Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Params = maps:get(<<"params">>, Msg, #{}),
    ToolName = maps:get(<<"name">>, Params, <<>>),
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    Tools = maps:get(tools, Server, []),
    case find_tool(ToolName, Tools) of
        {ok, #{handler := Handler}} ->
            case call_handler(Handler, Arguments, Timeout) of
                {ok, ContentResults} ->
                    {ok, #{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => #{
                            <<"content">> =>
                                [format_content(C) || C <- ContentResults]
                        }
                    }};
                {error, Reason} ->
                    {ok, #{
                        <<"jsonrpc">> => <<"2.0">>,
                        <<"id">> => Id,
                        <<"result">> => #{
                            <<"content">> => [#{
                                <<"type">> => <<"text">>,
                                <<"text">> => Reason
                            }],
                            <<"isError">> => true
                        }
                    }}
            end;
        error ->
            {ok, #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => Id,
                <<"error">> => #{
                    <<"code">> => -32602,
                    <<"message">> =>
                        <<"Unknown tool: ", ToolName/binary>>
                }
            }}
    end;

dispatch_jsonrpc(Msg, _Server, _Timeout) ->
    Id = maps:get(<<"id">>, Msg, null),
    Method = maps:get(<<"method">>, Msg, <<"unknown">>),
    MethodBin = if is_binary(Method) -> Method; true -> <<"unknown">> end,
    {ok, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => -32601,
            <<"message">> =>
                <<"Method not found: ", MethodBin/binary>>
        }
    }}.

%%--------------------------------------------------------------------
%% Internal: Helpers
%%--------------------------------------------------------------------

%% @doc Convert a tool_def to MCP wire format for tools/list.
-spec tool_to_mcp_format(tool_def()) -> map().
tool_to_mcp_format(#{name := Name, description := Desc,
                      input_schema := Schema}) ->
    #{<<"name">> => Name,
      <<"description">> => Desc,
      <<"inputSchema">> => Schema}.

%% @doc Find a tool by name in the tools list.
-spec find_tool(binary(), [tool_def()]) -> {ok, tool_def()} | error.
find_tool(_Name, []) -> error;
find_tool(Name, [#{name := Name} = Tool | _]) -> {ok, Tool};
find_tool(Name, [_ | Rest]) -> find_tool(Name, Rest).

%% @doc Find a tool by name across all servers in the registry.
-spec find_tool_in_registry(binary(), mcp_registry()) -> {ok, tool_def()} | error.
find_tool_in_registry(ToolName, Registry) ->
    maps:fold(fun
        (_ServerName, #{tools := Tools}, error) ->
            find_tool(ToolName, Tools);
        (_ServerName, _Server, {ok, _} = Found) ->
            Found
    end, error, Registry).

%% @doc Execute a tool handler with crash protection and configurable timeout.
%%      Spawns a monitored process to isolate handler crashes from
%%      the gen_statem.
-spec call_handler(tool_handler(), map(), pos_integer()) ->
    {ok, [content_result()]} | {error, binary()}.
call_handler(Handler, Input, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Result = try Handler(Input) of
            R -> R
        catch
            Class:Reason:Stack ->
                ErrMsg = iolist_to_binary(
                    io_lib:format("Handler ~p:~p~n~p",
                                  [Class, Reason, Stack])),
                {error, ErrMsg}
        end,
        Self ! {Ref, Result}
    end),
    receive
        {Ref, Result} ->
            demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, iolist_to_binary(
                io_lib:format("Handler crashed: ~p", [Reason]))}
    after Timeout ->
        demonitor(MRef, [flush]),
        exit(Pid, kill),
        %% Flush any result message sent before the kill took effect
        receive {Ref, _} -> ok after 0 -> ok end,
        TimeoutSecs = Timeout div 1000,
        {error, iolist_to_binary(
            io_lib:format("Tool handler timed out after ~B seconds", [TimeoutSecs]))}
    end.

%% @doc Format a content_result for the MCP wire protocol.
-spec format_content(content_result()) -> #{binary() => binary()}.
format_content(#{type := text, text := Text}) ->
    #{<<"type">> => <<"text">>, <<"text">> => Text};
format_content(#{type := image, data := Data, mime_type := MimeType}) ->
    #{<<"type">> => <<"image">>, <<"data">> => Data,
      <<"mimeType">> => MimeType}.
