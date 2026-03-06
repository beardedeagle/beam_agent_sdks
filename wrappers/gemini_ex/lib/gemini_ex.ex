defmodule GeminiEx do
  @moduledoc """
  Elixir wrapper for the Gemini CLI agent SDK.

  Provides idiomatic Elixir access to the Gemini CLI transport.
  Each query spawns a new port process (one-shot JSONL queries).
  Session IDs are captured from init events and reused automatically
  via --resume for subsequent queries within the same session process.

  ## Quick Start

      {:ok, session} = GeminiEx.start_session(cli_path: "gemini")
      {:ok, messages} = GeminiEx.query(session, "What is 2+2?")
      GeminiEx.stop(session)

  ## Streaming

      session
      |> GeminiEx.stream!("Explain quantum computing")
      |> Enum.each(&IO.inspect/1)

  ## Hooks

      hook = GeminiEx.sdk_hook(:post_tool_use, fn ctx ->
        IO.inspect(ctx, label: "tool used")
        :ok
      end)
      {:ok, session} = GeminiEx.start_session(cli_path: "gemini", sdk_hooks: [hook])
  """

  # ── Session Lifecycle ──────────────────────────────────────────────

  @doc "Start a Gemini CLI session (one-shot JSONL queries)."
  @spec start_session(keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    :gemini_cli_session.start_link(opts_to_map(opts))
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
    :gemini_cli_client.query(session, prompt, params)
  end

  # ── Streaming ──────────────────────────────────────────────────────

  @doc """
  Returns a `Stream` that yields messages as they arrive.

  Raises on errors. Uses `Stream.resource/3` under the hood.

  The query is dispatched to the CLI immediately when `stream!/3`
  is called. Message *consumption* is lazy/pull-based.

  ## Example

      session
      |> GeminiEx.stream!("Explain OTP")
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

  # ── Session Info & Runtime Control ─────────────────────────────────

  @doc "Query session health."
  @spec health(pid()) :: atom()
  def health(session) do
    :gen_statem.call(session, :health, 5_000)
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

  @doc "Interrupt the current query."
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
  Supervisor child specification for a gemini_cli_session process.

  Accepts keyword list or map. Uses `:session_id` from opts as child id
  when available.
  """
  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(opts) do
    map_opts = opts_to_map(opts)

    id =
      case Map.get(map_opts, :session_id) do
        nil -> :gemini_cli_session
        sid -> {:gemini_cli_session, sid}
      end

    %{
      id: id,
      start: {:gemini_cli_session, :start_link, [map_opts]},
      restart: :transient,
      shutdown: 10_000,
      type: :worker,
      modules: [:gemini_cli_session]
    }
  end

  # ── Content Block Generalization ──────────────────────────────────

  @doc """
  Normalize a list of messages from any adapter into a uniform flat stream.

  Claude produces `assistant` messages with nested `content_blocks`.
  All other adapters (including Gemini) produce individual typed messages.
  This function flattens both into a uniform stream where each message has
  a single, specific type — never nested content_blocks.

  ## Examples

      GeminiEx.normalize_messages(messages)
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

  # ── Additional Session Control ──────────────────────────────────────

  @doc "Change the permission mode at runtime via universal control."
  @spec set_permission_mode(pid(), binary()) :: {:ok, map()}
  def set_permission_mode(session, mode) do
    :gemini_cli_client.set_permission_mode(session, mode)
  end

  @doc "Send a raw control message via universal control dispatch."
  @spec send_control(pid(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def send_control(session, method, params \\ %{}) do
    :gemini_cli_client.send_control(session, method, params)
  end

  # ── SDK MCP Server Constructors ─────────────────────────────────────

  @doc "Create an in-process MCP tool definition."
  @spec mcp_tool(binary(), binary(), map(), (map() -> {:ok, list()} | {:error, binary()})) ::
          map()
  def mcp_tool(name, description, input_schema, handler) do
    :agent_wire_mcp.tool(name, description, input_schema, handler)
  end

  @doc "Create an in-process MCP server definition."
  @spec mcp_server(binary(), [map()]) :: map()
  def mcp_server(name, tools) do
    :agent_wire_mcp.server(name, tools)
  end

  # ── System Init Convenience Accessors ───────────────────────────────

  @doc "List available tools from the system init data."
  @spec list_tools(pid()) :: {:ok, list()} | {:error, term()}
  def list_tools(session), do: extract_system_field(session, :tools, [])

  @doc "List available skills from the system init data."
  @spec list_skills(pid()) :: {:ok, list()} | {:error, term()}
  def list_skills(session), do: extract_system_field(session, :skills, [])

  @doc "List available plugins from the system init data."
  @spec list_plugins(pid()) :: {:ok, list()} | {:error, term()}
  def list_plugins(session), do: extract_system_field(session, :plugins, [])

  @doc "List configured MCP servers from the system init data."
  @spec list_mcp_servers(pid()) :: {:ok, list()} | {:error, term()}
  def list_mcp_servers(session), do: extract_system_field(session, :mcp_servers, [])

  @doc "List available agents from the system init data."
  @spec list_agents(pid()) :: {:ok, list()} | {:error, term()}
  def list_agents(session), do: extract_system_field(session, :agents, [])

  @doc "Get the CLI version from the system init data."
  @spec cli_version(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def cli_version(session), do: extract_system_field(session, :claude_code_version, nil)

  @doc "Get the working directory from the system init data."
  @spec working_directory(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def working_directory(session), do: extract_system_field(session, :cwd, nil)

  @doc "Get the output style from the system init data."
  @spec output_style(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def output_style(session), do: extract_system_field(session, :output_style, nil)

  @doc "Get the API key source from the system init data."
  @spec api_key_source(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def api_key_source(session), do: extract_system_field(session, :api_key_source, nil)

  @doc "List active beta features from the system init data."
  @spec active_betas(pid()) :: {:ok, list()} | {:error, term()}
  def active_betas(session), do: extract_system_field(session, :betas, [])

  @doc """
  Get the current model from session info.

  Extracts from the session's model field or system init data.
  """
  @spec current_model(pid()) :: {:ok, binary() | nil} | {:error, term()}
  def current_model(session) do
    case session_info(session) do
      {:ok, %{model: model}} -> {:ok, model}
      {:ok, %{system_info: %{model: model}}} -> {:ok, model}
      {:ok, _} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  @doc "Get the current permission mode from session info."
  @spec current_permission_mode(pid()) :: {:ok, atom() | binary() | nil} | {:error, term()}
  def current_permission_mode(session) do
    extract_system_field(session, :permission_mode, nil)
  end

  @doc "Abort the current query. Alias for `interrupt/1`."
  @spec abort(pid()) :: :ok | {:error, term()}
  def abort(session), do: interrupt(session)

  # ── Universal: Session Store (agent_wire) ──────────────────────────

  @doc "List all tracked sessions."
  @spec list_sessions() :: {:ok, [map()]}
  def list_sessions, do: :gemini_cli_client.list_sessions()

  @doc "List sessions with filters."
  @spec list_sessions(map()) :: {:ok, [map()]}
  def list_sessions(opts) when is_map(opts), do: :gemini_cli_client.list_sessions(opts)

  @doc "Get messages for a session."
  @spec get_session_messages(binary()) :: {:ok, [map()]} | {:error, :not_found}
  def get_session_messages(session_id), do: :gemini_cli_client.get_session_messages(session_id)

  @doc "Get messages with options."
  @spec get_session_messages(binary(), map()) :: {:ok, [map()]} | {:error, :not_found}
  def get_session_messages(session_id, opts),
    do: :gemini_cli_client.get_session_messages(session_id, opts)

  @doc "Get session metadata by ID."
  @spec get_session(binary()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id), do: :gemini_cli_client.get_session(session_id)

  @doc "Delete a session and its messages."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_id), do: :gemini_cli_client.delete_session(session_id)

  # ── Universal: Thread Management (agent_wire) ──────────────────────

  @doc "Start a new conversation thread."
  @spec thread_start(pid(), map()) :: {:ok, map()}
  def thread_start(session, opts \\ %{}),
    do: :gemini_cli_client.thread_start(session, opts)

  @doc "Resume an existing thread."
  @spec thread_resume(pid(), binary()) :: {:ok, map()} | {:error, :not_found}
  def thread_resume(session, thread_id),
    do: :gemini_cli_client.thread_resume(session, thread_id)

  @doc "List all threads for this session."
  @spec thread_list(pid()) :: {:ok, [map()]}
  def thread_list(session), do: :gemini_cli_client.thread_list(session)

  # ── Universal: MCP Management (agent_wire) ─────────────────────────

  @doc "Get status of all MCP servers."
  @spec mcp_server_status(pid()) :: {:ok, map()}
  def mcp_server_status(session),
    do: :gemini_cli_client.mcp_server_status(session)

  @doc "Replace MCP server configurations."
  @spec set_mcp_servers(pid(), [map()]) :: {:ok, term()} | {:error, term()}
  def set_mcp_servers(session, servers),
    do: :gemini_cli_client.set_mcp_servers(session, servers)

  @doc "Reconnect a failed MCP server."
  @spec reconnect_mcp_server(pid(), binary()) :: {:ok, term()} | {:error, term()}
  def reconnect_mcp_server(session, server_name),
    do: :gemini_cli_client.reconnect_mcp_server(session, server_name)

  @doc "Enable or disable an MCP server."
  @spec toggle_mcp_server(pid(), binary(), boolean()) :: {:ok, term()} | {:error, term()}
  def toggle_mcp_server(session, server_name, enabled),
    do: :gemini_cli_client.toggle_mcp_server(session, server_name, enabled)

  # ── Universal: Init Response Accessors ─────────────────────────────

  @doc "List available slash commands."
  @spec supported_commands(pid()) :: {:ok, list()} | {:error, term()}
  def supported_commands(session), do: :gemini_cli_client.supported_commands(session)

  @doc "List available models."
  @spec supported_models(pid()) :: {:ok, list()} | {:error, term()}
  def supported_models(session), do: :gemini_cli_client.supported_models(session)

  @doc "List available agents."
  @spec supported_agents(pid()) :: {:ok, list()} | {:error, term()}
  def supported_agents(session), do: :gemini_cli_client.supported_agents(session)

  @doc "Get account information."
  @spec account_info(pid()) :: {:ok, map()} | {:error, term()}
  def account_info(session), do: :gemini_cli_client.account_info(session)

  # ── Universal: Session Control (agent_wire) ───────────────────────

  @doc "Set maximum thinking tokens via universal control."
  @spec set_max_thinking_tokens(pid(), pos_integer()) :: {:ok, map()}
  def set_max_thinking_tokens(session, max_tokens) do
    :gemini_cli_client.set_max_thinking_tokens(session, max_tokens)
  end

  @doc "Revert file changes to a checkpoint via universal checkpointing."
  @spec rewind_files(pid(), binary()) :: :ok | {:error, :not_found | term()}
  def rewind_files(session, checkpoint_uuid) do
    :gemini_cli_client.rewind_files(session, checkpoint_uuid)
  end

  @doc "Stop a running agent task via universal task tracking."
  @spec stop_task(pid(), binary()) :: :ok | {:error, :not_found}
  def stop_task(session, task_id) do
    :gemini_cli_client.stop_task(session, task_id)
  end

  @doc "Run a command via universal command execution."
  @spec command_run(pid(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def command_run(session, command, opts \\ %{}) do
    :gemini_cli_client.command_run(session, command, opts)
  end

  @doc "Submit feedback via universal feedback tracking."
  @spec submit_feedback(pid(), map()) :: :ok
  def submit_feedback(session, feedback) do
    :gemini_cli_client.submit_feedback(session, feedback)
  end

  @doc "Respond to an agent request via universal turn response."
  @spec turn_respond(pid(), binary(), map()) :: :ok | {:error, :not_found | :already_resolved}
  def turn_respond(session, request_id, params) do
    :gemini_cli_client.turn_respond(session, request_id, params)
  end

  @doc "Check server health. Maps to session health for Gemini."
  @spec server_health(pid()) :: {:ok, map()}
  def server_health(session), do: :gemini_cli_client.server_health(session)

  # ── Todo Extraction ─────────────────────────────────────────────────

  @doc "Extract all TodoWrite items from a list of messages."
  @spec extract_todos([map()]) :: [AgentWire.Todo.todo_item()]
  defdelegate extract_todos(messages), to: AgentWire.Todo

  @doc "Filter todo items by status."
  @spec filter_todos([AgentWire.Todo.todo_item()], AgentWire.Todo.todo_status()) ::
          [AgentWire.Todo.todo_item()]
  defdelegate filter_todos(todos, status), to: AgentWire.Todo, as: :filter_by_status

  @doc "Get a summary of todo counts by status."
  @spec todo_summary([AgentWire.Todo.todo_item()]) :: %{atom() => non_neg_integer()}
  defdelegate todo_summary(todos), to: AgentWire.Todo

  # ── Internal ───────────────────────────────────────────────────────

  defp opts_to_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_to_map(opts) when is_map(opts), do: opts

  defp extract_system_field(session, field, default) do
    case session_info(session) do
      {:ok, %{system_info: info}} when is_map(info) ->
        {:ok, Map.get(info, field, default)}

      {:ok, _} ->
        {:ok, default}

      {:error, _} = err ->
        err
    end
  end
end
