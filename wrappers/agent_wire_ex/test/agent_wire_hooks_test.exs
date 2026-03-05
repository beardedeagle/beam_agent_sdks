defmodule AgentWire.HooksTest do
  use ExUnit.Case, async: true

  describe "hook/2" do
    test "creates a hook without matcher" do
      hook = AgentWire.Hooks.hook(:pre_tool_use, fn _ctx -> :ok end)
      assert hook.event == :pre_tool_use
      assert is_function(hook.callback, 1)
      refute Map.has_key?(hook, :matcher)
    end
  end

  describe "hook/3" do
    test "creates a hook with tool_name matcher" do
      hook =
        AgentWire.Hooks.hook(
          :pre_tool_use,
          fn _ctx -> :ok end,
          %{tool_name: "Bash"}
        )

      assert hook.event == :pre_tool_use
      assert hook.matcher == %{tool_name: "Bash"}
      assert Map.has_key?(hook, :compiled_re)
    end

    test "creates a hook with regex matcher" do
      hook =
        AgentWire.Hooks.hook(
          :pre_tool_use,
          fn _ctx -> :ok end,
          %{tool_name: "Read.*"}
        )

      assert hook.matcher == %{tool_name: "Read.*"}
    end

    test "creates a hook with empty matcher (no tool_name)" do
      hook =
        AgentWire.Hooks.hook(
          :post_tool_use,
          fn _ctx -> :ok end,
          %{}
        )

      assert hook.event == :post_tool_use
      refute Map.has_key?(hook, :compiled_re)
    end
  end

  describe "registry management" do
    test "new_registry returns empty map" do
      assert AgentWire.Hooks.new_registry() == %{}
    end

    test "register_hook adds to registry" do
      hook = AgentWire.Hooks.hook(:stop, fn _ctx -> :ok end)

      registry =
        AgentWire.Hooks.new_registry()
        |> AgentWire.Hooks.register_hook(hook)

      assert Map.has_key?(registry, :stop)
      assert length(registry[:stop]) == 1
    end

    test "register_hooks adds multiple hooks" do
      h1 = AgentWire.Hooks.hook(:stop, fn _ctx -> :ok end)
      h2 = AgentWire.Hooks.hook(:session_start, fn _ctx -> :ok end)

      registry =
        AgentWire.Hooks.new_registry()
        |> AgentWire.Hooks.register_hooks([h1, h2])

      assert Map.has_key?(registry, :stop)
      assert Map.has_key?(registry, :session_start)
    end

    test "build_registry from list" do
      hooks = [
        AgentWire.Hooks.hook(:stop, fn _ctx -> :ok end),
        AgentWire.Hooks.hook(:stop, fn _ctx -> :ok end)
      ]

      registry = AgentWire.Hooks.build_registry(hooks)
      assert is_map(registry)
      assert length(registry[:stop]) == 2
    end

    test "build_registry returns nil for nil" do
      assert AgentWire.Hooks.build_registry(nil) == nil
    end

    test "build_registry returns nil for empty list" do
      assert AgentWire.Hooks.build_registry([]) == nil
    end
  end

  describe "fire/3" do
    test "fires notification hooks (always returns :ok)" do
      test_pid = self()

      hook =
        AgentWire.Hooks.hook(:post_tool_use, fn ctx ->
          send(test_pid, {:fired, ctx.tool_name})
          :ok
        end)

      registry = AgentWire.Hooks.build_registry([hook])
      context = %{event: :post_tool_use, tool_name: "Bash"}

      assert :ok = AgentWire.Hooks.fire(:post_tool_use, context, registry)
      assert_receive {:fired, "Bash"}
    end

    test "fires blocking hook that allows" do
      hook =
        AgentWire.Hooks.hook(:pre_tool_use, fn _ctx -> :ok end)

      registry = AgentWire.Hooks.build_registry([hook])
      context = %{event: :pre_tool_use, tool_name: "Read"}

      assert :ok = AgentWire.Hooks.fire(:pre_tool_use, context, registry)
    end

    test "fires blocking hook that denies" do
      hook =
        AgentWire.Hooks.hook(:pre_tool_use, fn _ctx ->
          {:deny, "Not allowed"}
        end)

      registry = AgentWire.Hooks.build_registry([hook])
      context = %{event: :pre_tool_use, tool_name: "Bash"}

      assert {:deny, "Not allowed"} =
               AgentWire.Hooks.fire(:pre_tool_use, context, registry)
    end

    test "matcher filters by tool_name" do
      test_pid = self()

      hook =
        AgentWire.Hooks.hook(
          :post_tool_use,
          fn _ctx ->
            send(test_pid, :fired)
            :ok
          end,
          %{tool_name: "Bash"}
        )

      registry = AgentWire.Hooks.build_registry([hook])

      # Should not fire for Read
      AgentWire.Hooks.fire(:post_tool_use, %{event: :post_tool_use, tool_name: "Read"}, registry)
      refute_receive :fired

      # Should fire for Bash
      AgentWire.Hooks.fire(:post_tool_use, %{event: :post_tool_use, tool_name: "Bash"}, registry)
      assert_receive :fired
    end

    test "handles nil registry gracefully" do
      assert :ok = AgentWire.Hooks.fire(:stop, %{event: :stop}, nil)
    end

    test "handles crash in callback gracefully" do
      hook =
        AgentWire.Hooks.hook(:post_tool_use, fn _ctx ->
          raise "boom"
        end)

      registry = AgentWire.Hooks.build_registry([hook])
      context = %{event: :post_tool_use, tool_name: "Bash"}

      # Should not crash, notification hooks swallow errors
      assert :ok = AgentWire.Hooks.fire(:post_tool_use, context, registry)
    end
  end
end
