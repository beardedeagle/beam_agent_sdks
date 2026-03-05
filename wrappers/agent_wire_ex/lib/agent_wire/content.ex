defmodule AgentWire.Content do
  @moduledoc """
  Content block handling for agent_wire messages.

  Provides bidirectional conversion between two message formats:

  1. **Content blocks** — Claude Code assistant messages carry a
     `content_blocks` list of heterogeneous blocks (text, thinking,
     tool_use, tool_result). This is the native Claude format.

  2. **Flat messages** — All other adapters (Codex, Gemini, OpenCode,
     Copilot) emit individual typed messages at the top level.

  Use these functions to write adapter-agnostic code by normalizing
  to whichever representation you prefer.

  ## Examples

      # Flatten any adapter's output into individual messages
      flat = AgentWire.Content.normalize_messages(messages)

      # Collect individual messages into content blocks
      blocks = AgentWire.Content.messages_to_blocks(messages)

  """

  @typedoc """
  A single content block inside an assistant message.

  Variants:
  - `%{type: :text, text: "..."}` — text content
  - `%{type: :thinking, thinking: "..."}` — thinking/reasoning
  - `%{type: :tool_use, id: "...", name: "...", input: %{}}` — tool call
  - `%{type: :tool_result, tool_use_id: "...", content: "..."}` — tool output
  - `%{type: :raw, raw: %{}}` — unknown block type (preserved)
  """
  @type content_block :: %{
          required(:type) => :text | :thinking | :tool_use | :tool_result | :raw,
          optional(:text) => binary(),
          optional(:thinking) => binary(),
          optional(:id) => binary(),
          optional(:name) => binary(),
          optional(:input) => map(),
          optional(:tool_use_id) => binary(),
          optional(:content) => binary(),
          optional(:raw) => map()
        }

  @doc """
  Parse a list of raw JSON content block maps into typed blocks.

  Non-map elements are silently dropped. Unknown block types are
  preserved as `:raw` blocks for forward compatibility.

  ## Examples

      blocks = AgentWire.Content.parse_blocks([
        %{"type" => "text", "text" => "Hello"},
        %{"type" => "thinking", "thinking" => "Let me think..."}
      ])

  """
  @spec parse_blocks(list()) :: [content_block()]
  def parse_blocks(blocks) when is_list(blocks) do
    :agent_wire_content.parse_blocks(blocks)
  end

  def parse_blocks(_), do: []

  @doc """
  Convert a single content block to a flat message.

  ## Examples

      msg = AgentWire.Content.block_to_message(%{type: :text, text: "Hello"})
      #=> %{type: :text, content: "Hello"}

  """
  @spec block_to_message(content_block()) :: AgentWire.message()
  def block_to_message(block) when is_map(block) do
    :agent_wire_content.block_to_message(block)
  end

  @doc """
  Convert a flat message to a content block.

  ## Examples

      block = AgentWire.Content.message_to_block(%{type: :text, content: "Hello"})
      #=> %{type: :text, text: "Hello"}

  """
  @spec message_to_block(AgentWire.message()) :: content_block()
  def message_to_block(message) when is_map(message) do
    :agent_wire_content.message_to_block(message)
  end

  @doc """
  Flatten an assistant message's content blocks into individual messages.

  If the message has `content_blocks`, each block is converted to a
  standalone message. Non-assistant messages pass through unchanged
  (wrapped in a list).

  ## Examples

      [text_msg, tool_msg] = AgentWire.Content.flatten_assistant(assistant_msg)

  """
  @spec flatten_assistant(AgentWire.message()) :: [AgentWire.message()]
  def flatten_assistant(message) when is_map(message) do
    :agent_wire_content.flatten_assistant(message)
  end

  @doc """
  Collect individual typed messages into content blocks.

  The inverse of `normalize_messages/1`. Useful for building the
  Claude-native content block format from flat messages.
  """
  @spec messages_to_blocks([AgentWire.message()]) :: [content_block()]
  def messages_to_blocks(messages) when is_list(messages) do
    :agent_wire_content.messages_to_blocks(messages)
  end

  @doc """
  Normalize any adapter's output into a uniform stream of flat messages.

  Assistant messages with `content_blocks` are expanded inline into
  individual typed messages. Everything else passes through unchanged.

  This is the primary function for writing adapter-agnostic code.

  ## Examples

      # Works identically regardless of which adapter produced the messages
      messages
      |> AgentWire.Content.normalize_messages()
      |> Enum.each(fn
        %{type: :text, content: text} -> IO.write(text)
        %{type: :tool_use, tool_name: name} -> IO.puts("Tool: \#{name}")
        _ -> :ok
      end)

  """
  @spec normalize_messages([AgentWire.message()]) :: [AgentWire.message()]
  def normalize_messages(messages) when is_list(messages) do
    :agent_wire_content.normalize_messages(messages)
  end
end
