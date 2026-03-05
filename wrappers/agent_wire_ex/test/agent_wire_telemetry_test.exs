defmodule AgentWire.TelemetryTest do
  use ExUnit.Case, async: true

  setup do
    test_pid = self()

    handler_id = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:agent_wire, :test_agent, :query, :start],
        [:agent_wire, :test_agent, :query, :stop],
        [:agent_wire, :test_agent, :query, :exception],
        [:agent_wire, :session, :state_change],
        [:agent_wire, :buffer, :overflow]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "span_start/3" do
    test "emits start event and returns monotonic time" do
      start_time = AgentWire.Telemetry.span_start(:test_agent, :query, %{prompt: "hi"})
      assert is_integer(start_time)

      assert_receive {:telemetry, [:agent_wire, :test_agent, :query, :start], %{system_time: _},
                      metadata}

      assert metadata.agent == :test_agent
      assert metadata.prompt == "hi"
    end
  end

  describe "span_stop/3" do
    test "emits stop event with duration" do
      start_time = AgentWire.Telemetry.span_start(:test_agent, :query, %{})
      :ok = AgentWire.Telemetry.span_stop(:test_agent, :query, start_time)

      # Flush start event
      assert_receive {:telemetry, [:agent_wire, :test_agent, :query, :start], _, _}

      assert_receive {:telemetry, [:agent_wire, :test_agent, :query, :stop],
                      %{duration: duration}, _}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "span_exception/3" do
    test "emits exception event" do
      :ok = AgentWire.Telemetry.span_exception(:test_agent, :query, :timeout)

      assert_receive {:telemetry, [:agent_wire, :test_agent, :query, :exception],
                      %{system_time: _}, metadata}

      assert metadata.agent == :test_agent
      assert metadata.reason == :timeout
    end
  end

  describe "state_change/3" do
    test "emits state change event" do
      :ok = AgentWire.Telemetry.state_change(:test_agent, :connecting, :ready)

      assert_receive {:telemetry, [:agent_wire, :session, :state_change], %{system_time: _},
                      metadata}

      assert metadata.agent == :test_agent
      assert metadata.from_state == :connecting
      assert metadata.to_state == :ready
    end
  end

  describe "buffer_overflow/2" do
    test "emits buffer overflow event" do
      :ok = AgentWire.Telemetry.buffer_overflow(2_500_000, 2_000_000)

      assert_receive {:telemetry, [:agent_wire, :buffer, :overflow], %{buffer_size: 2_500_000},
                      %{max: 2_000_000}}
    end
  end
end
