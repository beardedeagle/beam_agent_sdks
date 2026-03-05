defmodule CopilotEx do
  @moduledoc """
  Elixir wrapper for the Copilot CLI agent SDK.

  Provides idiomatic Elixir access to `copilot_session` (Erlang/OTP
  gen_statem) with lazy streaming via `Stream.resource/3`.

  ## Quick Start

      {:ok, session} = CopilotEx.start_session(cli_path: "copilot")
      {:ok, messages} = CopilotEx.query(session, "What is 2 + 2?")
      CopilotEx.stop(session)

  ## Streaming

      session
      |> CopilotEx.stream!("Explain OTP supervision trees")
      |> Enum.each(fn msg ->
        case msg.type do
          :text   -> IO.write(msg.content)
          :result -> IO.puts("\\nDone!")
          _       -> :ok
        end
      end)

  ## Session Options

  - `:cli_path` - Path to the Copilot CLI executable (default: `"copilot"`)
  - `:work_dir` - Working directory for the CLI subprocess
  - `:env` - Environment variables as `[{key, value}]` charlists
  - `:buffer_max` - Max raw binary buffer in bytes (default: 2MB)
  - `:session_id` - Resume a previous session (binary)
  - `:model` - Model to use (binary)
  - `:system_prompt` - System prompt (binary)
  - `:max_turns` - Maximum number of turns
  - `:permission_mode` - Permission mode (binary)
  - `:permission_handler` - `fn(request, invocation, opts) -> result` callback
  - `:allowed_tools` - List of allowed tool names
  - `:disallowed_tools` - List of disallowed tool names
  - `:mcp_servers` - MCP server configurations (map)
  - `:output_format` - Structured output JSON schema (map)
  - `:thinking` - Thinking configuration (map)
  - `:effort` - Effort level (binary)
  - `:sdk_mcp_servers` - In-process MCP servers (list of server maps).
    All adapters share this unified API via `agent_wire_mcp`.
  - `:sdk_hooks` - SDK lifecycle hooks (list of hook maps)
  - `:user_input_handler` - User input request handler function
  - `:protocol_version` - Copilot protocol version (default: 3)

  ## In-Process MCP Tools

  Register tools via the unified `agent_wire_mcp` API (same as all adapters):

      tool = :agent_wire_mcp.tool("weather", "Get weather",
        %{"type" => "object",
          "properties" => %{"city" => %{"type" => "string"}}},
        fn args ->
          city = Map.get(args, "city", "unknown")
          {:ok, [%{type: :text, text: "72F in \#{city}"}]}
        end)
      server = :agent_wire_mcp.server("my-tools", [tool])
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        sdk_mcp_servers: [server]
      )

  ## Permission Handling

  Register a handler for Copilot permission requests (fail-closed by default):

      handler = fn request, _invocation, _opts ->
        case request do
          %{"kind" => "file_write"} -> {:allow, %{}}
          _ -> {:deny, "Not allowed"}
        end
      end
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        permission_handler: handler
      )
  """

  # -- Session Lifecycle ---------------------------------------------------

  @doc """
  Start a new Copilot CLI session.

  Returns `{:ok, pid}` on success. The session process speaks
  full bidirectional JSON-RPC 2.0 over Content-Length framed stdio.

  ## Examples

      {:ok, session} = CopilotEx.start_session(cli_path: "copilot")
      {:ok, session} = CopilotEx.start_session(
        cli_path: "copilot",
        model: "gpt-4o",
        permission_mode: "acceptEdits"
      )
  """
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts \\ []) do
    opts
    |> opts_to_map()
    |> :copilot_session.start_link()
  end

  @doc "Gracefully stop a session, closing the CLI subprocess."
  @spec stop(pid()) :: :ok
  def stop(session) do
    :copilot_client.stop(session)
  end

  # -- Blocking Query ------------------------------------------------------

  @doc """
  Send a query and collect all response messages (blocking).

  Returns `{:ok, messages}` once the query completes (session.idle).
  Uses deadline-based timeout.

  ## Options

    * `:timeout` - total query timeout in ms (default: 120_000)

  ## Examples

      {:ok, messages} = CopilotEx.query(session, "Hello!")
      last = List.last(messages)
      IO.puts(last.content)
  """
  @spec query(pid(), binary(), map()) :: {:ok, [map()]} | {:error, term()}
  def query(session, prompt, params \\ %{}) do
    :copilot_client.query(session, prompt, params)
  end

  # -- Streaming -----------------------------------------------------------

  @doc """
  Returns a `Stream` that yields messages as they arrive.

  Raises on errors. Uses `Stream.resource/3` under the hood with
  demand-driven backpressure — the gen_statem only delivers the
  next message when the stream consumer requests it.

  The query is dispatched to the CLI immediately when `stream!/3`
  is called (not lazily on first consumption). Message *consumption*
  is lazy/pull-based.

  The stream halts automatically when a `:result` or terminal `:error`
  message is received. Note: Copilot can emit non-terminal `:error`
  messages (warnings), so the halt condition checks `is_error: true`
  — unlike other adapters where all `:error` messages are terminal.

  ## Examples

      CopilotEx.stream!(session, "Explain GenServer")
      |> Stream.filter(& &1.type == :text)
      |> Enum.map(& &1.content)
      |> Enum.join("")

      # With options
      CopilotEx.stream!(session, "Hello", %{timeout: 60_000})
      |> Enum.to_list()
  """
  @spec stream!(pid(), binary(), map()) :: Enumerable.t()
  def stream!(session, prompt, params \\ %{}) do
    timeout = Map.get(params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :gen_statem.call(session, {:send_query, prompt, params}, timeout) do
          {:ok, ref} -> {session, ref, deadline}
          {:error, reason} -> raise "Query failed: #{inspect(reason)}"
        end
      end,
      fn
        {:done, _, _, _} = done ->
          {:halt, done}

        {sess, ref, dl} ->
          remaining = dl - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            raise "Stream error: timeout"
          else
            case :gen_statem.call(sess, {:receive_message, ref}, remaining) do
              {:ok, %{type: :result} = msg} -> {[msg], {:done, sess, ref, dl}}
              {:ok, %{type: :error, is_error: true} = msg} -> {[msg], {:done, sess, ref, dl}}
              {:ok, msg} -> {[msg], {sess, ref, dl}}
              {:error, :complete} -> {:halt, {sess, ref, dl}}
              {:error, reason} -> raise "Stream error: #{inspect(reason)}"
            end
          end
      end,
      fn
        {:done, _, _, _} -> :ok
        {_, _, _} -> :ok
        _ -> :ok
      end
    )
  end

  @doc """
  Returns a `Stream` that yields `{:ok, msg}` or `{:error, reason}` tuples.

  Non-raising variant of `stream!/3`.
  """
  @spec stream(pid(), binary(), map()) :: Enumerable.t()
  def stream(session, prompt, params \\ %{}) do
    timeout = Map.get(params, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.resource(
      fn ->
        case :gen_statem.call(session, {:send_query, prompt, params}, timeout) do
          {:ok, ref} -> {session, ref, deadline}
          {:error, _} = err -> {:error_init, err}
        end
      end,
      fn
        {:error_init, err} ->
          {[err], :halt_state}

        :halt_state ->
          {:halt, :halt_state}

        {sess, ref, dl} ->
          remaining = dl - System.monotonic_time(:millisecond)

          if remaining <= 0 do
            {[{:error, :timeout}], :halt_state}
          else
            case :gen_statem.call(sess, {:receive_message, ref}, remaining) do
              {:ok, %{type: :result} = msg} -> {[{:ok, msg}], :halt_state}
              {:ok, %{type: :error, is_error: true} = msg} -> {[{:ok, msg}], :halt_state}
              {:ok, msg} -> {[{:ok, msg}], {sess, ref, dl}}
              {:error, :complete} -> {:halt, {sess, ref, dl}}
              {:error, reason} -> {[{:error, reason}], :halt_state}
            end
          end
      end,
      fn _ -> :ok end
    )
  end

  # -- Session Info & Runtime Control --------------------------------------

  @doc """
  Get the current health/state of a session.

  ## Examples

      :ready = CopilotEx.health(session)
  """
  @spec health(pid()) :: :connecting | :initializing | :ready | :active_query | :error
  def health(session) do
    :copilot_client.health(session)
  end

  @doc """
  Query session info (adapter, session_id, model, etc.).

  ## Examples

      {:ok, info} = CopilotEx.session_info(session)
      info.copilot_session_id
  """
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :copilot_client.session_info(session)
  end

  @doc """
  Change the model at runtime during a session.

  ## Examples

      {:ok, _} = CopilotEx.set_model(session, "gpt-4o")
  """
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :copilot_client.set_model(session, model)
  end

  @doc """
  Interrupt/abort the current active query.

  ## Examples

      :ok = CopilotEx.interrupt(session)
  """
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :copilot_client.interrupt(session)
  end

  @doc "Abort the current active query. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session) do
    :copilot_client.abort(session)
  end

  # -- Arbitrary Control ---------------------------------------------------

  @doc """
  Send an arbitrary JSON-RPC command to the Copilot CLI.

  ## Examples

      {:ok, result} = CopilotEx.send_command(session, "config.get", %{})
  """
  @spec send_command(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_command(session, method, params \\ %{}) do
    :copilot_client.send_command(session, method, params)
  end

  # -- SDK Hook Constructors -----------------------------------------------

  @doc """
  Create an SDK lifecycle hook.

  Hooks fire at key session lifecycle points. Events:
  - `:pre_tool_use` - before tool execution (can deny)
  - `:post_tool_use` - after tool result received
  - `:stop` - when result/completion received
  - `:session_start` - when session enters ready state
  - `:session_end` - when session terminates
  - `:user_prompt_submit` - before query sent (can deny)

  ## Examples

      hook = CopilotEx.sdk_hook(:pre_tool_use, fn ctx ->
        case ctx.tool_name do
          "Bash" -> {:deny, "No shell access"}
          _ -> :ok
        end
      end)
      {:ok, session} = CopilotEx.start_session(sdk_hooks: [hook])
  """
  @spec sdk_hook(atom(), function()) :: map()
  def sdk_hook(event, callback) do
    :agent_wire_hooks.hook(event, callback)
  end

  @doc """
  Create an SDK lifecycle hook with a matcher filter.

  ## Examples

      hook = CopilotEx.sdk_hook(:pre_tool_use,
        fn _ctx -> {:deny, "blocked"} end,
        %{tool_name: "Bash"})
  """
  @spec sdk_hook(atom(), function(), map()) :: map()
  def sdk_hook(event, callback, matcher) do
    :agent_wire_hooks.hook(event, callback, matcher)
  end

  # -- Supervisor Integration ----------------------------------------------

  @doc """
  Supervisor child specification for a copilot_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.

  ## Examples

      children = [
        {CopilotEx, cli_path: "copilot", work_dir: "/my/project"}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    map_opts = opts_to_map(opts)

    id =
      case Map.get(map_opts, :session_id) do
        nil -> :copilot_session
        sid -> {:copilot_session, sid}
      end

    %{
      id: id,
      start: {:copilot_session, :start_link, [map_opts]},
      restart: :transient,
      shutdown: 10_000,
      type: :worker,
      modules: [:copilot_session]
    }
  end

  # -- Content Block Generalization -----------------------------------------

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Copilot) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      CopilotEx.normalize_messages(messages)
      |> Enum.filter(& &1.type == :text)
      |> Enum.map(& &1.content)
      |> Enum.join("")
  """
  @spec normalize_messages([map()]) :: [map()]
  def normalize_messages(messages) do
    :agent_wire_content.normalize_messages(messages)
  end

  @doc "Flatten an assistant message (with content_blocks) into individual messages."
  @spec flatten_assistant(map()) :: [map()]
  def flatten_assistant(message), do: :agent_wire_content.flatten_assistant(message)

  @doc "Convert a list of flat messages into content_block format."
  @spec messages_to_blocks([map()]) :: [map()]
  def messages_to_blocks(messages), do: :agent_wire_content.messages_to_blocks(messages)

  @doc "Convert a single content_block into a flat message."
  @spec block_to_message(map()) :: map()
  def block_to_message(block), do: :agent_wire_content.block_to_message(block)

  @doc "Convert a single flat message into a content_block."
  @spec message_to_block(map()) :: map()
  def message_to_block(message), do: :agent_wire_content.message_to_block(message)

  # -- Internal ------------------------------------------------------------

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts
end
