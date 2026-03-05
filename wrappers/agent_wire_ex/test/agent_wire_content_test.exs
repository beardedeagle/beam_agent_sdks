defmodule AgentWire.ContentTest do
  use ExUnit.Case, async: true

  describe "parse_blocks/1" do
    test "parses text block" do
      blocks =
        AgentWire.Content.parse_blocks([
          %{"type" => "text", "text" => "Hello"}
        ])

      assert [%{type: :text, text: "Hello"}] = blocks
    end

    test "parses thinking block" do
      blocks =
        AgentWire.Content.parse_blocks([
          %{"type" => "thinking", "thinking" => "Let me think..."}
        ])

      assert [%{type: :thinking, thinking: "Let me think..."}] = blocks
    end

    test "parses tool_use block" do
      blocks =
        AgentWire.Content.parse_blocks([
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "Bash",
            "input" => %{"command" => "ls"}
          }
        ])

      assert [%{type: :tool_use, id: "tu_1", name: "Bash", input: %{"command" => "ls"}}] = blocks
    end

    test "preserves unknown types as raw" do
      blocks =
        AgentWire.Content.parse_blocks([
          %{"type" => "future_type", "data" => "stuff"}
        ])

      assert [%{type: :raw, raw: %{"type" => "future_type", "data" => "stuff"}}] = blocks
    end

    test "drops non-map elements" do
      blocks = AgentWire.Content.parse_blocks(["not a map", 42, nil])
      assert blocks == []
    end

    test "handles non-list input" do
      assert AgentWire.Content.parse_blocks("not a list") == []
    end
  end

  describe "block_to_message/1 and message_to_block/1" do
    test "round-trips text" do
      block = %{type: :text, text: "Hello"}
      msg = AgentWire.Content.block_to_message(block)
      assert msg.type == :text
      assert msg.content == "Hello"

      back = AgentWire.Content.message_to_block(msg)
      assert back.type == :text
      assert back.text == "Hello"
    end

    test "round-trips tool_use" do
      block = %{type: :tool_use, id: "tu_1", name: "Bash", input: %{"cmd" => "ls"}}
      msg = AgentWire.Content.block_to_message(block)
      assert msg.type == :tool_use
      assert msg.tool_name == "Bash"

      back = AgentWire.Content.message_to_block(msg)
      assert back.type == :tool_use
      assert back.name == "Bash"
    end
  end

  describe "normalize_messages/1" do
    test "passes flat messages through unchanged" do
      msgs = [
        %{type: :text, content: "hello"},
        %{type: :result, content: "done"}
      ]

      normalized = AgentWire.Content.normalize_messages(msgs)
      assert length(normalized) == 2
      assert Enum.at(normalized, 0).type == :text
      assert Enum.at(normalized, 1).type == :result
    end

    test "expands assistant messages with content_blocks" do
      msgs = [
        %{
          type: :assistant,
          content_blocks: [
            %{type: :text, text: "Hello"},
            %{type: :tool_use, id: "tu_1", name: "Bash", input: %{}}
          ]
        }
      ]

      normalized = AgentWire.Content.normalize_messages(msgs)
      assert length(normalized) == 2
      assert Enum.at(normalized, 0).type == :text
      assert Enum.at(normalized, 1).type == :tool_use
    end
  end

  describe "messages_to_blocks/1" do
    test "converts flat messages to blocks" do
      msgs = [
        %{type: :text, content: "hello"},
        %{type: :thinking, content: "hmm"}
      ]

      blocks = AgentWire.Content.messages_to_blocks(msgs)
      assert length(blocks) == 2
      assert Enum.at(blocks, 0).type == :text
      assert Enum.at(blocks, 1).type == :thinking
    end
  end

  describe "flatten_assistant/1" do
    test "flattens assistant with content blocks" do
      msg = %{
        type: :assistant,
        content_blocks: [
          %{type: :text, text: "Hi"},
          %{type: :thinking, thinking: "..."}
        ]
      }

      flat = AgentWire.Content.flatten_assistant(msg)
      assert length(flat) == 2
    end

    test "wraps non-assistant messages in list" do
      msg = %{type: :text, content: "hello"}
      assert [^msg] = AgentWire.Content.flatten_assistant(msg)
    end
  end
end
