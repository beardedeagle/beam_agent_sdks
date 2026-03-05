defmodule CodexExTest do
  use ExUnit.Case, async: true

  # Ensure module is loaded before function_exported? checks
  setup_all do
    {:module, _} = Code.ensure_loaded(CodexEx)
    :ok
  end

  # ── Option conversion ────────────────────────────────────────────

  describe "opts_to_map (via child_spec)" do
    test "keyword list converts to map" do
      spec = CodexEx.child_spec(cli_path: "/usr/bin/codex")
      assert %{id: :codex_session} = spec
      assert %{start: {:codex_session, :start_link, [opts]}} = spec
      assert is_map(opts)
      assert opts.cli_path == "/usr/bin/codex"
    end

    test "session_id is used in child_spec id" do
      spec = CodexEx.child_spec(cli_path: "codex", session_id: "s1")
      assert %{id: {:codex_session, "s1"}} = spec
    end
  end

  # ── Child spec structure ─────────────────────────────────────────

  describe "child_spec" do
    test "has correct structure" do
      spec = CodexEx.child_spec(cli_path: "codex")
      assert %{restart: :transient, shutdown: 10_000, type: :worker} = spec
      assert %{modules: [:codex_session]} = spec
    end
  end

  # ── SDK hook constructors ────────────────────────────────────────

  describe "sdk_hook" do
    test "creates a hook without matcher" do
      hook = CodexEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end)
      assert is_map(hook)
      assert hook.event == :pre_tool_use
    end

    test "creates a hook with matcher" do
      hook =
        CodexEx.sdk_hook(:pre_tool_use, fn _ctx -> :ok end, %{tool_name: "Read"})

      assert is_map(hook)
      assert hook.event == :pre_tool_use
      assert is_map(hook.matcher)
    end
  end

  # ── Session module ───────────────────────────────────────────────

  describe "CodexEx.Session" do
    test "send_control delegates to codex_session" do
      # codex_exec returns {:error, :not_supported} — tests function exists
      assert {:error, :not_supported} =
               :codex_exec.send_control(self(), "method", %{})
    end
  end

  # ── Thread management functions exist ────────────────────────────

  describe "thread management" do
    test "thread_start/2 is exported" do
      assert function_exported?(CodexEx, :thread_start, 2)
    end

    test "thread_resume/2 is exported" do
      assert function_exported?(CodexEx, :thread_resume, 2)
    end

    test "thread_list/1 is exported" do
      assert function_exported?(CodexEx, :thread_list, 1)
    end
  end

  # ── Stream functions are exported ────────────────────────────────

  describe "stream functions" do
    test "stream!/3 is exported" do
      assert function_exported?(CodexEx, :stream!, 3)
    end

    test "stream/3 is exported" do
      assert function_exported?(CodexEx, :stream, 3)
    end
  end

  # ── Start functions are exported ─────────────────────────────────

  describe "start functions" do
    test "start_session/1 is exported" do
      assert function_exported?(CodexEx, :start_session, 1)
    end

    test "start_exec/1 is exported" do
      assert function_exported?(CodexEx, :start_exec, 1)
    end
  end

  # ── Content Block Generalization ──────────────────────────────────

  describe "normalize_messages/1" do
    test "flattens assistant messages inline" do
      messages = [
        %{type: :assistant, content_blocks: [
          %{type: :text, text: "hello"}
        ]},
        %{type: :result}
      ]

      flat = CodexEx.normalize_messages(messages)
      types = Enum.map(flat, & &1.type)
      assert types == [:text, :result]
    end

    test "passes through Codex-style flat messages unchanged" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :tool_use, tool_name: "bash", tool_input: %{}},
        %{type: :result, content: ""}
      ]

      assert CodexEx.normalize_messages(messages) == messages
    end
  end

  describe "content block conversion" do
    test "round-trip text block" do
      block = %{type: :text, text: "hello"}
      assert block == CodexEx.message_to_block(CodexEx.block_to_message(block))
    end

    test "messages_to_blocks converts flat messages" do
      blocks = CodexEx.messages_to_blocks([%{type: :text, content: "hi"}])
      assert length(blocks) == 1
      assert hd(blocks).type == :text
      assert hd(blocks).text == "hi"
    end
  end
end
