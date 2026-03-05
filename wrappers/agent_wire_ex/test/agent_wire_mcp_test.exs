defmodule AgentWire.MCPTest do
  use ExUnit.Case, async: true

  describe "tool/4" do
    test "creates a tool definition" do
      handler = fn _input -> {:ok, [%{type: :text, text: "hi"}]} end

      tool =
        AgentWire.MCP.tool(
          "greet",
          "Greet someone",
          %{"type" => "object"},
          handler
        )

      assert tool.name == "greet"
      assert tool.description == "Greet someone"
      assert tool.input_schema == %{"type" => "object"}
      assert is_function(tool.handler, 1)
    end
  end

  describe "server/2,3" do
    test "creates a server with default version" do
      tool = AgentWire.MCP.tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = AgentWire.MCP.server("my-server", [tool])

      assert server.name == "my-server"
      assert server.version == "1.0.0"
      assert length(server.tools) == 1
    end

    test "creates a server with explicit version" do
      server = AgentWire.MCP.server("my-server", [], "2.0.0")
      assert server.version == "2.0.0"
    end
  end

  describe "registry management" do
    test "new_registry returns empty map" do
      assert AgentWire.MCP.new_registry() == %{}
    end

    test "register_server and server_names" do
      tool = AgentWire.MCP.tool("t", "d", %{}, fn _ -> {:ok, []} end)
      server = AgentWire.MCP.server("tools", [tool])

      registry =
        AgentWire.MCP.new_registry()
        |> AgentWire.MCP.register_server(server)

      assert AgentWire.MCP.server_names(registry) == ["tools"]
    end

    test "build_registry from list" do
      s1 = AgentWire.MCP.server("a", [])
      s2 = AgentWire.MCP.server("b", [])
      registry = AgentWire.MCP.build_registry([s1, s2])

      assert is_map(registry)
      names = AgentWire.MCP.server_names(registry) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "build_registry returns nil for nil" do
      assert AgentWire.MCP.build_registry(nil) == nil
    end

    test "build_registry returns nil for empty list" do
      assert AgentWire.MCP.build_registry([]) == nil
    end
  end

  describe "dispatch" do
    setup do
      tool =
        AgentWire.MCP.tool(
          "echo",
          "Echo input",
          %{"type" => "object"},
          fn input ->
            text = Map.get(input, "text", "")
            {:ok, [%{type: :text, text: text}]}
          end
        )

      server = AgentWire.MCP.server("test-server", [tool])
      registry = AgentWire.MCP.build_registry([server])
      %{registry: registry}
    end

    test "handle_mcp_message tools/list", %{registry: registry} do
      msg = %{"method" => "tools/list", "id" => 1}
      {:ok, response} = AgentWire.MCP.handle_mcp_message("test-server", msg, registry)
      assert response["id"] == 1
      tools = response["result"]["tools"]
      assert length(tools) == 1
      assert hd(tools)["name"] == "echo"
    end

    test "handle_mcp_message tools/call", %{registry: registry} do
      msg = %{
        "method" => "tools/call",
        "id" => 2,
        "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
      }

      {:ok, response} = AgentWire.MCP.handle_mcp_message("test-server", msg, registry)
      assert response["id"] == 2
      [content] = response["result"]["content"]
      assert content["type"] == "text"
      assert content["text"] == "hello"
    end

    test "handle_mcp_message unknown server", %{registry: registry} do
      msg = %{"method" => "tools/list", "id" => 3}
      {:error, reason} = AgentWire.MCP.handle_mcp_message("nope", msg, registry)
      assert reason =~ "Unknown MCP server"
    end

    test "call_tool_by_name", %{registry: registry} do
      {:ok, results} = AgentWire.MCP.call_tool_by_name("echo", %{"text" => "hi"}, registry)
      assert [%{type: :text, text: "hi"}] = results
    end

    test "call_tool_by_name unknown tool", %{registry: registry} do
      {:error, reason} = AgentWire.MCP.call_tool_by_name("nope", %{}, registry)
      assert reason =~ "Unknown tool"
    end

    test "all_tool_definitions", %{registry: registry} do
      tools = AgentWire.MCP.all_tool_definitions(registry)
      assert length(tools) == 1
      assert hd(tools).name == "echo"
    end
  end

  describe "CLI integration" do
    test "servers_for_cli" do
      server = AgentWire.MCP.server("my-tools", [])
      registry = AgentWire.MCP.build_registry([server])
      cli_config = AgentWire.MCP.servers_for_cli(registry)

      assert %{"mcpServers" => servers} = cli_config
      assert Map.has_key?(servers, "my-tools")
      assert servers["my-tools"]["type"] == "sdk"
    end

    test "servers_for_init" do
      server = AgentWire.MCP.server("my-tools", [])
      registry = AgentWire.MCP.build_registry([server])
      names = AgentWire.MCP.servers_for_init(registry)
      assert names == ["my-tools"]
    end
  end
end
