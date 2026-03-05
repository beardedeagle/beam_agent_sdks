defmodule AgentWireTest do
  use ExUnit.Case, async: true

  describe "normalize_message/1" do
    test "normalizes a text message" do
      raw = %{"type" => "text", "content" => "hello"}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :text
      assert msg.content == "hello"
      assert is_integer(msg.timestamp)
    end

    test "normalizes a result message" do
      raw = %{"type" => "result", "result" => "done", "duration_ms" => 100}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :result
      assert msg.content == "done"
      assert msg.duration_ms == 100
    end

    test "normalizes an error message" do
      raw = %{"type" => "error", "content" => "boom"}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :error
      assert msg.content == "boom"
    end

    test "normalizes unknown type as raw" do
      raw = %{"type" => "future_type", "data" => "stuff"}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :raw
      assert msg.raw == raw
    end

    test "normalizes typeless map as raw" do
      raw = %{"no_type" => true}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :raw
      assert msg.raw == raw
    end

    test "extracts common fields (uuid, session_id)" do
      raw = %{
        "type" => "text",
        "content" => "hi",
        "uuid" => "abc-123",
        "session_id" => "sess-456"
      }

      msg = AgentWire.normalize_message(raw)
      assert msg.uuid == "abc-123"
      assert msg.session_id == "sess-456"
    end

    test "normalizes tool_use message" do
      raw = %{
        "type" => "tool_use",
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "ls"}
      }

      msg = AgentWire.normalize_message(raw)
      assert msg.type == :tool_use
      assert msg.tool_name == "Bash"
      assert msg.tool_input == %{"command" => "ls"}
    end

    test "normalizes thinking message" do
      raw = %{"type" => "thinking", "thinking" => "Let me consider..."}
      msg = AgentWire.normalize_message(raw)
      assert msg.type == :thinking
      assert msg.content == "Let me consider..."
    end
  end

  describe "make_request_id/0" do
    test "returns a binary starting with req_" do
      id = AgentWire.make_request_id()
      assert is_binary(id)
      assert String.starts_with?(id, "req_")
    end

    test "returns unique IDs" do
      ids = for _ <- 1..100, do: AgentWire.make_request_id()
      assert length(Enum.uniq(ids)) == 100
    end
  end

  describe "parse_stop_reason/1" do
    test "parses known stop reasons" do
      assert AgentWire.parse_stop_reason("end_turn") == :end_turn
      assert AgentWire.parse_stop_reason("max_tokens") == :max_tokens
      assert AgentWire.parse_stop_reason("stop_sequence") == :stop_sequence
      assert AgentWire.parse_stop_reason("refusal") == :refusal
      assert AgentWire.parse_stop_reason("tool_use") == :tool_use_stop
    end

    test "returns unknown_stop for unrecognized reasons" do
      assert AgentWire.parse_stop_reason("something_new") == :unknown_stop
      assert AgentWire.parse_stop_reason(nil) == :unknown_stop
    end
  end

  describe "parse_permission_mode/1" do
    test "parses known permission modes" do
      assert AgentWire.parse_permission_mode("default") == :default
      assert AgentWire.parse_permission_mode("acceptEdits") == :accept_edits
      assert AgentWire.parse_permission_mode("bypassPermissions") == :bypass_permissions
      assert AgentWire.parse_permission_mode("plan") == :plan
      assert AgentWire.parse_permission_mode("dontAsk") == :dont_ask
    end

    test "returns default for unrecognized modes" do
      assert AgentWire.parse_permission_mode("unknown") == :default
      assert AgentWire.parse_permission_mode(nil) == :default
    end
  end
end
