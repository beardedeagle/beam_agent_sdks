defmodule AgentWire.Control do
  @moduledoc """
  Universal session control protocol for agent sessions.

  Provides session-scoped configuration state, task tracking,
  feedback management, and turn response handling. Implements a
  virtual control protocol for adapters without native control
  message support.

  Uses ETS for per-session state. All state is keyed by session_id
  and persists for the node lifetime or until explicitly cleared.

  ## Configuration

      AgentWire.Control.set_permission_mode("sess_1", "acceptEdits")
      {:ok, "acceptEdits"} = AgentWire.Control.get_permission_mode("sess_1")

  ## Control Dispatch

      {:ok, %{model: "claude-sonnet-4-6"}} =
        AgentWire.Control.dispatch("sess_1", "setModel", %{"model" => "claude-sonnet-4-6"})

  ## Task Tracking

      AgentWire.Control.register_task("sess_1", "task_1", self())
      :ok = AgentWire.Control.stop_task("sess_1", "task_1")

  ## Feedback

      AgentWire.Control.submit_feedback("sess_1", %{rating: :good})
      {:ok, feedbacks} = AgentWire.Control.get_feedback("sess_1")

  ## Pending Requests (Turn Response)

      AgentWire.Control.store_pending_request("sess_1", "req_1", %{prompt: "Yes or no?"})
      :ok = AgentWire.Control.resolve_pending_request("sess_1", "req_1", %{answer: "Yes"})

  """

  @typedoc "Task metadata."
  @type task_meta :: %{
          required(:task_id) => binary(),
          required(:session_id) => binary(),
          required(:pid) => pid(),
          required(:started_at) => integer(),
          required(:status) => :running | :stopped
        }

  @typedoc "Pending request metadata."
  @type pending_request :: %{
          required(:request_id) => binary(),
          required(:session_id) => binary(),
          required(:request) => map(),
          required(:status) => :pending | :resolved,
          optional(:response) => map(),
          required(:created_at) => integer(),
          optional(:resolved_at) => integer()
        }

  # ── Table Lifecycle ────────────────────────────────────────────────

  @doc "Ensure all control ETS tables exist. Idempotent."
  @spec ensure_tables() :: :ok
  def ensure_tables, do: :agent_wire_control.ensure_tables()

  @doc "Clear all control state."
  @spec clear() :: :ok
  def clear, do: :agent_wire_control.clear()

  # ── Control Dispatch ───────────────────────────────────────────────

  @doc """
  Dispatch a control method to the appropriate handler.

  Known methods: `setModel`, `setPermissionMode`, `setMaxThinkingTokens`, `stopTask`.

  ## Examples

      {:ok, %{model: "gpt-4"}} = AgentWire.Control.dispatch("s1", "setModel", %{"model" => "gpt-4"})
      {:error, {:unknown_method, "foo"}} = AgentWire.Control.dispatch("s1", "foo", %{})

  """
  @spec dispatch(binary(), binary(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(session_id, method, params)
      when is_binary(session_id) and is_binary(method) and is_map(params) do
    :agent_wire_control.dispatch(session_id, method, params)
  end

  # ── Session Config ─────────────────────────────────────────────────

  @doc "Get a config value for a session."
  @spec get_config(binary(), atom()) :: {:ok, term()} | {:error, :not_set}
  def get_config(session_id, key) when is_binary(session_id) and is_atom(key) do
    :agent_wire_control.get_config(session_id, key)
  end

  @doc "Set a config value for a session."
  @spec set_config(binary(), atom(), term()) :: :ok
  def set_config(session_id, key, value) when is_binary(session_id) and is_atom(key) do
    :agent_wire_control.set_config(session_id, key, value)
  end

  @doc "Get all config for a session as a map."
  @spec get_all_config(binary()) :: {:ok, map()}
  def get_all_config(session_id) when is_binary(session_id) do
    :agent_wire_control.get_all_config(session_id)
  end

  @doc "Clear all config for a session."
  @spec clear_config(binary()) :: :ok
  def clear_config(session_id) when is_binary(session_id) do
    :agent_wire_control.clear_config(session_id)
  end

  # ── Permission Mode ────────────────────────────────────────────────

  @doc "Set the permission mode for a session."
  @spec set_permission_mode(binary(), binary() | atom()) :: :ok
  def set_permission_mode(session_id, mode) when is_binary(session_id) do
    :agent_wire_control.set_permission_mode(session_id, mode)
  end

  @doc "Get the permission mode for a session."
  @spec get_permission_mode(binary()) :: {:ok, binary() | atom()} | {:error, :not_set}
  def get_permission_mode(session_id) when is_binary(session_id) do
    :agent_wire_control.get_permission_mode(session_id)
  end

  # ── Thinking Tokens ────────────────────────────────────────────────

  @doc "Set max thinking tokens for a session."
  @spec set_max_thinking_tokens(binary(), pos_integer()) :: :ok
  def set_max_thinking_tokens(session_id, tokens)
      when is_binary(session_id) and is_integer(tokens) and tokens > 0 do
    :agent_wire_control.set_max_thinking_tokens(session_id, tokens)
  end

  @doc "Get max thinking tokens for a session."
  @spec get_max_thinking_tokens(binary()) :: {:ok, pos_integer()} | {:error, :not_set}
  def get_max_thinking_tokens(session_id) when is_binary(session_id) do
    :agent_wire_control.get_max_thinking_tokens(session_id)
  end

  # ── Task Tracking ──────────────────────────────────────────────────

  @doc "Register an active task for a session."
  @spec register_task(binary(), binary(), pid()) :: :ok
  def register_task(session_id, task_id, pid)
      when is_binary(session_id) and is_binary(task_id) and is_pid(pid) do
    :agent_wire_control.register_task(session_id, task_id, pid)
  end

  @doc "Unregister a task (mark as complete)."
  @spec unregister_task(binary(), binary()) :: :ok
  def unregister_task(session_id, task_id)
      when is_binary(session_id) and is_binary(task_id) do
    :agent_wire_control.unregister_task(session_id, task_id)
  end

  @doc """
  Stop a running task by sending an interrupt to its process.

  Returns `:ok` if the task was found and signaled,
  `{:error, :not_found}` if the task doesn't exist.
  """
  @spec stop_task(binary(), binary()) :: :ok | {:error, :not_found}
  def stop_task(session_id, task_id)
      when is_binary(session_id) and is_binary(task_id) do
    :agent_wire_control.stop_task(session_id, task_id)
  end

  @doc "List all tasks for a session."
  @spec list_tasks(binary()) :: {:ok, [task_meta()]}
  def list_tasks(session_id) when is_binary(session_id) do
    :agent_wire_control.list_tasks(session_id)
  end

  # ── Feedback ───────────────────────────────────────────────────────

  @doc "Submit feedback for a session. Feedback is accumulated."
  @spec submit_feedback(binary(), map()) :: :ok
  def submit_feedback(session_id, feedback)
      when is_binary(session_id) and is_map(feedback) do
    :agent_wire_control.submit_feedback(session_id, feedback)
  end

  @doc "Get all feedback for a session, in submission order."
  @spec get_feedback(binary()) :: {:ok, [map()]}
  def get_feedback(session_id) when is_binary(session_id) do
    :agent_wire_control.get_feedback(session_id)
  end

  @doc "Clear all feedback for a session."
  @spec clear_feedback(binary()) :: :ok
  def clear_feedback(session_id) when is_binary(session_id) do
    :agent_wire_control.clear_feedback(session_id)
  end

  # ── Pending Requests (Turn Response) ───────────────────────────────

  @doc "Store a pending request from the agent."
  @spec store_pending_request(binary(), binary(), map()) :: :ok
  def store_pending_request(session_id, request_id, request)
      when is_binary(session_id) and is_binary(request_id) and is_map(request) do
    :agent_wire_control.store_pending_request(session_id, request_id, request)
  end

  @doc """
  Resolve a pending request with a response.

  Returns `:ok` on success, `{:error, :already_resolved}` if already
  resolved, or `{:error, :not_found}` if the request doesn't exist.
  """
  @spec resolve_pending_request(binary(), binary(), map()) ::
          :ok | {:error, :not_found | :already_resolved}
  def resolve_pending_request(session_id, request_id, response)
      when is_binary(session_id) and is_binary(request_id) and is_map(response) do
    :agent_wire_control.resolve_pending_request(session_id, request_id, response)
  end

  @doc """
  Get the response for a pending request.

  Returns `{:ok, response}` if resolved, `{:error, :pending}` if
  still waiting, or `{:error, :not_found}` if the request doesn't exist.
  """
  @spec get_pending_response(binary(), binary()) ::
          {:ok, map()} | {:error, :pending | :not_found}
  def get_pending_response(session_id, request_id)
      when is_binary(session_id) and is_binary(request_id) do
    :agent_wire_control.get_pending_response(session_id, request_id)
  end

  @doc "List all pending requests for a session."
  @spec list_pending_requests(binary()) :: {:ok, [pending_request()]}
  def list_pending_requests(session_id) when is_binary(session_id) do
    :agent_wire_control.list_pending_requests(session_id)
  end
end
