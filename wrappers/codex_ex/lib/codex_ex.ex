defmodule CodexEx do
  @moduledoc """
  Elixir wrapper for the Codex CLI agent SDK.

  Provides idiomatic Elixir access to the Codex app-server and exec
  transports. For most use cases, use `start_session/1` for full
  bidirectional JSON-RPC or `start_exec/1` for simpler one-shot queries.

  ## Quick Start

      {:ok, session} = CodexEx.start_session(cli_path: "codex")
      {:ok, messages} = CodexEx.query(session, "What is 2+2?")
      CodexEx.stop(session)

  ## Streaming

      session
      |> CodexEx.stream!("Explain quantum computing")
      |> Enum.each(&IO.inspect/1)

  ## Thread Management (app-server only)

      {:ok, %{"threadId" => tid}} = CodexEx.thread_start(session, %{})
      {:ok, messages} = CodexEx.query(session, "Follow-up question")
  """

  # ── Session Lifecycle ──────────────────────────────────────────────

  @doc "Start a Codex app-server session (full bidirectional JSON-RPC)."
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    :codex_session.start_link(opts_to_map(opts))
  end

  @doc "Start a Codex exec session (one-shot JSONL queries)."
  @spec start_exec(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_exec(opts) do
    :codex_exec.start_link(opts_to_map(opts))
  end

  @doc "Stop a session."
  @spec stop(pid()) :: :ok
  def stop(session) do
    :gen_statem.stop(session, :normal, 10_000)
  end

  # ── Blocking Query ─────────────────────────────────────────────────

  @doc """
  Send a query and collect all response messages (blocking).

  Returns `{:ok, messages}` where messages is a list of `agent_wire`
  message maps. Uses deadline-based timeout.

  ## Options

    * `:timeout` - total query timeout in ms (default: 120_000)
  """
  @spec query(pid(), binary(), map()) :: {:ok, [map()]} | {:error, term()}
  def query(session, prompt, params \\ %{}) do
    :codex_app_server.query(session, prompt, params)
  end

  # ── Streaming ──────────────────────────────────────────────────────

  @doc """
  Returns a `Stream` that yields messages as they arrive.

  Raises on errors. Uses `Stream.resource/3` under the hood.

  The query is dispatched to the CLI immediately when `stream!/3`
  is called. Message *consumption* is lazy/pull-based.

  ## Example

      session
      |> CodexEx.stream!("Explain OTP")
      |> Enum.each(fn msg -> IO.puts(msg.content) end)
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
              {:ok, %{type: :error} = msg} -> {[msg], {:done, sess, ref, dl}}
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
              {:ok, %{type: :error} = msg} -> {[{:ok, msg}], :halt_state}
              {:ok, msg} -> {[{:ok, msg}], {sess, ref, dl}}
              {:error, :complete} -> {:halt, {sess, ref, dl}}
              {:error, reason} -> {[{:error, reason}], :halt_state}
            end
          end
      end,
      fn _ -> :ok end
    )
  end

  # ── Thread Management (app-server only) ────────────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), map()) :: {:ok, map()} | {:error, term()}
  def thread_start(session, opts \\ %{}) do
    :codex_session.send_control(
      session,
      "thread/start",
      :codex_protocol.thread_start_params(opts)
    )
  end

  @doc "Resume an existing thread by ID."
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, term()}
  def thread_resume(session, thread_id) do
    :codex_session.send_control(session, "thread/resume", %{"threadId" => thread_id})
  end

  @doc "List all threads."
  @spec thread_list(pid()) :: {:ok, [map()]} | {:error, term()}
  def thread_list(session) do
    :codex_session.send_control(session, "thread/list", %{})
  end

  # ── Session Info & Runtime Control ─────────────────────────────────

  @doc "Query session health."
  @spec health(pid()) :: atom()
  def health(session) do
    :codex_app_server.health(session)
  end

  @doc "Query session info."
  @spec session_info(pid()) :: {:ok, map()} | {:error, term()}
  def session_info(session) do
    :gen_statem.call(session, :session_info, 5_000)
  end

  @doc "Change the model at runtime."
  @spec set_model(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def set_model(session, model) do
    :gen_statem.call(session, {:set_model, model}, 5_000)
  end

  @doc "Interrupt the current turn."
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(session) do
    :gen_statem.call(session, :interrupt, 5_000)
  end

  # ── SDK Hook Constructors ──────────────────────────────────────────

  @doc "Create an SDK lifecycle hook."
  @spec sdk_hook(atom(), function()) :: map()
  def sdk_hook(event, callback) do
    :agent_wire_hooks.hook(event, callback)
  end

  @doc "Create an SDK lifecycle hook with a matcher."
  @spec sdk_hook(atom(), function(), map()) :: map()
  def sdk_hook(event, callback, matcher) do
    :agent_wire_hooks.hook(event, callback, matcher)
  end

  # ── Supervisor Integration ─────────────────────────────────────────

  @doc """
  Supervisor child specification for a codex_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    map_opts = opts_to_map(opts)

    id =
      case Map.get(map_opts, :session_id) do
        nil -> :codex_session
        sid -> {:codex_session, sid}
      end

    %{
      id: id,
      start: {:codex_session, :start_link, [map_opts]},
      restart: :transient,
      shutdown: 10_000,
      type: :worker,
      modules: [:codex_session]
    }
  end

  # ── Content Block Generalization ──────────────────────────────────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Codex) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      CodexEx.normalize_messages(messages)
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

  # ── Internal ───────────────────────────────────────────────────────

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts
end
