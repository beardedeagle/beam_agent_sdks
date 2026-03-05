defmodule AgentWire.MCP do
  @moduledoc """
  In-process MCP server support for BEAM Agent SDKs.

  Define custom tools as Elixir functions that AI agents can call
  in-process via the MCP protocol. Tools are grouped into servers,
  and servers are collected into a registry.

  ## Quick Start

      # Define a tool
      tool = AgentWire.MCP.tool(
        "lookup_user",
        "Look up a user by ID",
        %{"type" => "object",
          "properties" => %{"id" => %{"type" => "string"}}},
        fn input ->
          id = Map.get(input, "id", "")
          {:ok, [%{type: :text, text: "User: \#{id}"}]}
        end
      )

      # Group into a server
      server = AgentWire.MCP.server("my-tools", [tool])

      # Pass to any adapter session
      {:ok, session} = ClaudeEx.start_session(sdk_mcp_servers: [server])

  ## Registry Management

  For advanced use cases, you can manage registries directly:

      registry =
        AgentWire.MCP.new_registry()
        |> AgentWire.MCP.register_server(server1)
        |> AgentWire.MCP.register_server(server2)

      AgentWire.MCP.server_names(registry)
      #=> ["my-tools", "other-tools"]

  """

  @typedoc """
  Tool handler function. Receives arguments map, returns content results.
  """
  @type tool_handler :: (map() -> {:ok, [content_result()]} | {:error, binary()})

  @typedoc """
  Content result from a tool handler.
  """
  @type content_result ::
          %{type: :text, text: binary()}
          | %{type: :image, data: binary(), mime_type: binary()}

  @typedoc """
  Tool definition with name, description, JSON schema, and handler.
  """
  @type tool_def :: %{
          name: binary(),
          description: binary(),
          input_schema: map(),
          handler: tool_handler()
        }

  @typedoc """
  SDK MCP server grouping tools under a name.
  """
  @type sdk_mcp_server :: %{
          required(:name) => binary(),
          required(:tools) => [tool_def()],
          optional(:version) => binary()
        }

  @typedoc """
  Registry mapping server names to their definitions.
  """
  @type mcp_registry :: %{binary() => sdk_mcp_server()}

  # -------------------------------------------------------------------
  # Constructors
  # -------------------------------------------------------------------

  @doc """
  Create a tool definition.

  ## Parameters

  - `name` — unique tool name (binary)
  - `description` — human-readable description (binary)
  - `input_schema` — JSON Schema for the tool's input (map)
  - `handler` — `fn(input) -> {:ok, results} | {:error, reason}`

  ## Examples

      AgentWire.MCP.tool("greet", "Greet someone", %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      }, fn input ->
        name = Map.get(input, "name", "world")
        {:ok, [%{type: :text, text: "Hello, \#{name}!"}]}
      end)

  """
  @spec tool(binary(), binary(), map(), tool_handler()) :: tool_def()
  def tool(name, description, input_schema, handler)
      when is_binary(name) and is_binary(description) and
             is_map(input_schema) and is_function(handler, 1) do
    :agent_wire_mcp.tool(name, description, input_schema, handler)
  end

  @doc """
  Create an SDK MCP server with default version `"1.0.0"`.

  ## Examples

      server = AgentWire.MCP.server("my-tools", [tool1, tool2])

  """
  @spec server(binary(), [tool_def()]) :: sdk_mcp_server()
  def server(name, tools) when is_binary(name) and is_list(tools) do
    :agent_wire_mcp.server(name, tools)
  end

  @doc """
  Create an SDK MCP server with an explicit version.

  ## Examples

      server = AgentWire.MCP.server("my-tools", [tool], "2.0.0")

  """
  @spec server(binary(), [tool_def()], binary()) :: sdk_mcp_server()
  def server(name, tools, version)
      when is_binary(name) and is_list(tools) and is_binary(version) do
    :agent_wire_mcp.server(name, tools, version)
  end

  # -------------------------------------------------------------------
  # Registry Management
  # -------------------------------------------------------------------

  @doc """
  Create an empty MCP server registry.
  """
  @spec new_registry() :: mcp_registry()
  def new_registry, do: :agent_wire_mcp.new_registry()

  @doc """
  Register an SDK MCP server in the registry.

  ## Examples

      registry =
        AgentWire.MCP.new_registry()
        |> AgentWire.MCP.register_server(server)

  """
  @spec register_server(mcp_registry(), sdk_mcp_server()) :: mcp_registry()
  def register_server(registry, server) do
    :agent_wire_mcp.register_server(server, registry)
  end

  @doc """
  Get the list of server names in the registry.
  """
  @spec server_names(mcp_registry()) :: [binary()]
  def server_names(registry) do
    :agent_wire_mcp.server_names(registry)
  end

  @doc """
  Build an MCP registry from a list of server definitions.

  Returns `nil` when no servers are configured (empty list or `nil`).
  This is the convenience function used by all adapter session modules.

  ## Examples

      registry = AgentWire.MCP.build_registry([server1, server2])

  """
  @spec build_registry([sdk_mcp_server()] | nil) :: mcp_registry() | nil
  def build_registry(nil), do: nil

  def build_registry(servers) when is_list(servers) do
    case :agent_wire_mcp.build_registry(servers) do
      :undefined -> nil
      registry -> registry
    end
  end

  # -------------------------------------------------------------------
  # CLI Integration
  # -------------------------------------------------------------------

  @doc """
  Build the `--mcp-config` JSON map for CLI invocation.

  Produces the wire format expected by Claude Code CLI.
  """
  @spec servers_for_cli(mcp_registry()) :: map()
  def servers_for_cli(registry) do
    :agent_wire_mcp.servers_for_cli(registry)
  end

  @doc """
  Build the `sdkMcpServers` list for the initialize control request.
  """
  @spec servers_for_init(mcp_registry()) :: [binary()]
  def servers_for_init(registry) do
    :agent_wire_mcp.servers_for_init(registry)
  end

  # -------------------------------------------------------------------
  # Dispatch
  # -------------------------------------------------------------------

  @doc """
  Handle an MCP JSON-RPC message for a named server.

  Uses the default handler timeout of 30 seconds.

  ## Supported Methods

  - `"initialize"` — capabilities and server info
  - `"notifications/initialized"` — no-op acknowledgment
  - `"tools/list"` — tool definitions in MCP format
  - `"tools/call"` — execute handler, wrap result
  """
  @spec handle_mcp_message(binary(), map(), mcp_registry()) ::
          {:ok, map()} | {:error, binary()}
  def handle_mcp_message(server_name, message, registry) do
    :agent_wire_mcp.handle_mcp_message(server_name, message, registry)
  end

  @doc """
  Handle an MCP JSON-RPC message with options.

  ## Options

  - `:handler_timeout` — timeout in ms for tool handlers (default: 30000)
  """
  @spec handle_mcp_message(binary(), map(), mcp_registry(), map()) ::
          {:ok, map()} | {:error, binary()}
  def handle_mcp_message(server_name, message, registry, opts) do
    :agent_wire_mcp.handle_mcp_message(server_name, message, registry, opts)
  end

  @doc """
  Call a tool by name, searching across all servers in the registry.

  Uses the default handler timeout of 30 seconds.
  """
  @spec call_tool_by_name(binary(), map(), mcp_registry()) ::
          {:ok, [content_result()]} | {:error, binary()}
  def call_tool_by_name(tool_name, arguments, registry) do
    :agent_wire_mcp.call_tool_by_name(tool_name, arguments, registry)
  end

  @doc """
  Call a tool by name with options.

  ## Options

  - `:handler_timeout` — timeout in ms for tool handlers (default: 30000)
  """
  @spec call_tool_by_name(binary(), map(), mcp_registry(), map()) ::
          {:ok, [content_result()]} | {:error, binary()}
  def call_tool_by_name(tool_name, arguments, registry, opts) do
    :agent_wire_mcp.call_tool_by_name(tool_name, arguments, registry, opts)
  end

  @doc """
  Get all tool definitions from the registry, flattened across servers.
  """
  @spec all_tool_definitions(mcp_registry()) :: [tool_def()]
  def all_tool_definitions(registry) do
    :agent_wire_mcp.all_tool_definitions(registry)
  end
end
