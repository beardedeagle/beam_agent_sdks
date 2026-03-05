defmodule AgentWire.Telemetry do
  @moduledoc """
  Telemetry event helpers for BEAM Agent SDK adapters.

  All adapters emit `:telemetry` events for session lifecycle and
  query spans. This module provides consistent event emission and
  documents the event namespace.

  ## Event Namespace

  All events are prefixed with `[:agent_wire, ...]`:

  **Query spans** (per-adapter):
  - `[:agent_wire, agent, :query, :start]` — query initiated
  - `[:agent_wire, agent, :query, :stop]` — query completed (with duration)
  - `[:agent_wire, agent, :query, :exception]` — query failed

  **Session lifecycle**:
  - `[:agent_wire, :session, :state_change]` — gen_statem state transition

  **Buffer events**:
  - `[:agent_wire, :buffer, :overflow]` — message buffer exceeded limit

  ## Attaching Handlers

      :telemetry.attach("my-handler",
        [:agent_wire, :claude, :query, :stop],
        &handle_event/4,
        %{}
      )

  Libraries emit events; applications handle them. No OTLP export
  is built in — bring your own telemetry handlers.
  """

  @doc """
  Emit a span start event. Returns monotonic start time for duration
  calculation in `span_stop/3`.

  ## Parameters

  - `agent` — adapter atom (e.g., `:claude`, `:codex`, `:gemini`)
  - `event_suffix` — span name atom (e.g., `:query`)
  - `metadata` — additional context map

  Emits: `[:agent_wire, agent, event_suffix, :start]`
  """
  @spec span_start(atom(), atom(), map()) :: integer()
  def span_start(agent, event_suffix, metadata) when is_atom(agent) and is_atom(event_suffix) do
    :agent_wire_telemetry.span_start(agent, event_suffix, metadata)
  end

  @doc """
  Emit a span stop event with duration measurement.

  ## Parameters

  - `agent` — adapter atom
  - `event_suffix` — span name atom
  - `start_time` — monotonic start time from `span_start/3`

  Emits: `[:agent_wire, agent, event_suffix, :stop]`
  """
  @spec span_stop(atom(), atom(), integer()) :: :ok
  def span_stop(agent, event_suffix, start_time) when is_atom(agent) and is_atom(event_suffix) do
    :agent_wire_telemetry.span_stop(agent, event_suffix, start_time)
  end

  @doc """
  Emit a span exception event.

  ## Parameters

  - `agent` — adapter atom
  - `event_suffix` — span name atom
  - `reason` — exception reason term

  Emits: `[:agent_wire, agent, event_suffix, :exception]`
  """
  @spec span_exception(atom(), atom(), term()) :: :ok
  def span_exception(agent, event_suffix, reason) when is_atom(agent) and is_atom(event_suffix) do
    :agent_wire_telemetry.span_exception(agent, event_suffix, reason)
  end

  @doc """
  Emit a state change event for gen_statem transitions.

  Emits: `[:agent_wire, :session, :state_change]`
  """
  @spec state_change(atom(), atom(), atom()) :: :ok
  def state_change(agent, from_state, to_state)
      when is_atom(agent) and is_atom(from_state) and is_atom(to_state) do
    :agent_wire_telemetry.state_change(agent, from_state, to_state)
  end

  @doc """
  Emit a buffer overflow warning.

  Emits: `[:agent_wire, :buffer, :overflow]`
  """
  @spec buffer_overflow(pos_integer(), pos_integer()) :: :ok
  def buffer_overflow(buffer_size, max) when is_integer(buffer_size) and is_integer(max) do
    :agent_wire_telemetry.buffer_overflow(buffer_size, max)
  end
end
