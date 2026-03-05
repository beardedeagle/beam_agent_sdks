defmodule AgentWire do
  @moduledoc """
  Idiomatic Elixir interface for the `agent_wire` shared foundation.

  Provides common types, message normalization, and utility functions
  shared across all five BEAM Agent SDK adapters. This module wraps
  the Erlang `:agent_wire` module with Elixir conventions.

  ## Message Types

  All adapters normalize messages into a common `t:message/0` map type:

      %{type: :text, content: "Hello!"}
      %{type: :tool_use, tool_name: "Bash", tool_input: %{...}}
      %{type: :result, content: "Final answer", duration_ms: 5432}
      %{type: :error, content: "Something went wrong"}

  Pattern match on `:type` for adapter-agnostic dispatch:

      case message do
        %{type: :text, content: content} -> IO.write(content)
        %{type: :result} -> IO.puts("Done!")
        _ -> :ok
      end

  ## Stop Reasons

  Parsed from binary wire format into atoms:

  - `:end_turn` — normal completion
  - `:max_tokens` — token limit reached
  - `:stop_sequence` — stop sequence hit
  - `:refusal` — model refused
  - `:tool_use_stop` — stopped for tool use
  - `:unknown_stop` — unrecognized reason (forward-compatible)

  ## Permission Modes

  - `:default` — standard permissions
  - `:accept_edits` — auto-accept file edits
  - `:bypass_permissions` — skip all permission checks
  - `:plan` — plan mode (no side effects)
  - `:dont_ask` — never prompt (TypeScript SDK only)

  ## See Also

  - `AgentWire.MCP` — in-process MCP server registry and tool dispatch
  - `AgentWire.Hooks` — SDK lifecycle hooks
  - `AgentWire.Content` — content block conversion
  - `AgentWire.Telemetry` — telemetry event helpers
  """

  @typedoc """
  Normalized message type atoms across all five wire protocols.
  """
  @type message_type ::
          :text
          | :assistant
          | :tool_use
          | :tool_result
          | :system
          | :result
          | :error
          | :user
          | :control
          | :control_request
          | :control_response
          | :stream_event
          | :rate_limit_event
          | :tool_progress
          | :tool_use_summary
          | :thinking
          | :auth_status
          | :prompt_suggestion
          | :raw

  @typedoc """
  Stop reason atoms parsed from the wire format.
  """
  @type stop_reason ::
          :end_turn
          | :max_tokens
          | :stop_sequence
          | :refusal
          | :tool_use_stop
          | :unknown_stop

  @typedoc """
  Permission mode atoms.
  """
  @type permission_mode ::
          :default
          | :accept_edits
          | :bypass_permissions
          | :plan
          | :dont_ask

  @typedoc """
  Unified message map. Required key: `:type`.

  All other keys are optional and depend on the message type.
  See the Erlang `agent_wire` module docs for the full field reference.
  """
  @type message :: %{required(:type) => message_type, optional(atom) => term}

  @typedoc """
  Permission handler result.

  - `{:allow, updated_input}` — approve with optional input modification
  - `{:deny, reason}` — deny with reason message
  - `{:allow, updated_input, rule_update}` — approve with rule modification
  """
  @type permission_result ::
          {:allow, map()}
          | {:deny, binary()}
          | {:allow, map(), map()}

  @typedoc """
  Function that pulls the next message from a session.
  """
  @type receive_fun :: (pid(), reference(), timeout() -> {:ok, message()} | {:error, term()})

  @typedoc """
  Predicate that determines if a message terminates collection.
  """
  @type terminal_pred :: (message() -> boolean())

  @doc """
  Normalize a raw decoded JSON map into a unified `t:message/0`.

  Adapters call this after decoding their wire-format-specific JSON
  to produce the common message type. Extracts common fields (uuid,
  session_id) and delegates to type-specific field extraction.

  ## Examples

      iex> AgentWire.normalize_message(%{"type" => "text", "content" => "hello"})
      %{type: :text, content: "hello", raw: %{"type" => "text", "content" => "hello"}, timestamp: _}

  """
  @spec normalize_message(map()) :: message()
  def normalize_message(raw) when is_map(raw) do
    :agent_wire.normalize_message(raw)
  end

  @doc """
  Generate a unique request ID for control protocol correlation.

  Format: `req_COUNTER_HEX` (e.g., `"req_0_a1b2c3d4"`).

  ## Examples

      iex> id = AgentWire.make_request_id()
      iex> String.starts_with?(id, "req_")
      true

  """
  @spec make_request_id() :: binary()
  def make_request_id do
    :agent_wire.make_request_id()
  end

  @doc """
  Parse a binary stop reason into a typed atom.

  Unknown values map to `:unknown_stop` for forward compatibility.

  ## Examples

      iex> AgentWire.parse_stop_reason("end_turn")
      :end_turn

      iex> AgentWire.parse_stop_reason("something_new")
      :unknown_stop

  """
  @spec parse_stop_reason(binary() | term()) :: stop_reason()
  def parse_stop_reason(reason) do
    :agent_wire.parse_stop_reason(reason)
  end

  @doc """
  Parse a binary permission mode into a typed atom.

  Unknown values default to `:default`.

  ## Examples

      iex> AgentWire.parse_permission_mode("bypassPermissions")
      :bypass_permissions

      iex> AgentWire.parse_permission_mode("unknown")
      :default

  """
  @spec parse_permission_mode(binary() | term()) :: permission_mode()
  def parse_permission_mode(mode) do
    :agent_wire.parse_permission_mode(mode)
  end

  @doc """
  Collect all messages from a session until a terminal message is received.

  Uses the default terminal predicate: `:result` and `:error` messages
  halt the loop. The `receive_fun` is the adapter-specific function that
  pulls the next message.

  Returns `{:ok, messages}` in order, or `{:error, reason}` on timeout
  or transport failure.

  ## Parameters

  - `session` — session process PID
  - `ref` — query reference from `send_query`
  - `deadline` — absolute monotonic deadline in milliseconds
  - `receive_fun` — `fn(session, ref, timeout) -> {:ok, msg} | {:error, reason}`

  """
  @spec collect_messages(pid(), reference(), integer(), receive_fun()) ::
          {:ok, [message()]} | {:error, term()}
  def collect_messages(session, ref, deadline, receive_fun) do
    :agent_wire.collect_messages(session, ref, deadline, receive_fun)
  end

  @doc """
  Collect all messages with a custom terminal predicate.

  The predicate receives each message and returns `true` if collection
  should stop (the message is included in the result). This allows
  adapters with different halt semantics to customize behavior.

  ## Parameters

  - `session` — session process PID
  - `ref` — query reference from `send_query`
  - `deadline` — absolute monotonic deadline in milliseconds
  - `receive_fun` — pulls next message from session
  - `terminal_pred` — `fn(message) -> boolean()` determining when to stop

  """
  @spec collect_messages(pid(), reference(), integer(), receive_fun(), terminal_pred()) ::
          {:ok, [message()]} | {:error, term()}
  def collect_messages(session, ref, deadline, receive_fun, terminal_pred) do
    :agent_wire.collect_messages(session, ref, deadline, receive_fun, terminal_pred)
  end
end
