defmodule AgentWire.Hooks do
  @moduledoc """
  SDK lifecycle hooks for BEAM Agent SDKs.

  Register in-process callback functions that fire at key session
  lifecycle points. Hooks can block actions (pre_tool_use) or observe
  them (post_tool_use, stop).

  ## Hook Events

  **Blocking** (may return `{:deny, reason}` to prevent the action):
  - `:pre_tool_use` — before a tool is executed
  - `:user_prompt_submit` — before a user prompt is sent

  **Notification-only** (`{:deny, _}` returns are ignored):
  - `:post_tool_use` — after a tool completes
  - `:stop` — session is stopping
  - `:session_start` — session has started
  - `:session_end` — session has ended

  ## Quick Start

      # Block dangerous tool calls
      hook = AgentWire.Hooks.hook(:pre_tool_use, fn ctx ->
        case Map.get(ctx, :tool_name, "") do
          "Bash" -> {:deny, "Shell access denied"}
          _ -> :ok
        end
      end)

      # Pass to any adapter session
      {:ok, session} = ClaudeEx.start_session(sdk_hooks: [hook])

  ## Matchers

  Optional matchers filter which tools a hook fires on:

      # Only fire for Read* tools (regex)
      hook = AgentWire.Hooks.hook(:pre_tool_use, callback, %{tool_name: "Read.*"})

      # Only fire for Bash (exact match)
      hook = AgentWire.Hooks.hook(:pre_tool_use, callback, %{tool_name: "Bash"})

  """

  @typedoc """
  Hook event atoms matching the TypeScript/Python SDKs.
  """
  @type hook_event ::
          :pre_tool_use
          | :post_tool_use
          | :stop
          | :session_start
          | :session_end
          | :user_prompt_submit

  @typedoc """
  Hook callback function. Receives context map, returns `:ok` or `{:deny, reason}`.
  """
  @type hook_callback :: (hook_context() -> :ok | {:deny, binary()})

  @typedoc """
  Context map passed to hook callbacks. Keys depend on event type.
  """
  @type hook_context :: %{
          required(:event) => hook_event(),
          optional(:session_id) => binary(),
          optional(:tool_name) => binary(),
          optional(:tool_input) => map(),
          optional(:tool_use_id) => binary(),
          optional(:agent_id) => binary(),
          optional(:content) => binary(),
          optional(:stop_reason) => binary() | atom(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:prompt) => binary(),
          optional(:params) => map(),
          optional(:system_info) => map(),
          optional(:reason) => term()
        }

  @typedoc """
  Matcher for filtering which tools a hook fires on.
  """
  @type hook_matcher :: %{optional(:tool_name) => binary()}

  @typedoc """
  A single hook definition.
  """
  @type hook_def :: %{
          required(:event) => hook_event(),
          required(:callback) => hook_callback(),
          optional(:matcher) => hook_matcher()
        }

  @typedoc """
  Hook registry: event to list of hook definitions.
  """
  @type hook_registry :: %{hook_event() => [hook_def()]}

  # -------------------------------------------------------------------
  # Constructors
  # -------------------------------------------------------------------

  @doc """
  Create a hook that fires on all occurrences of an event.

  ## Examples

      AgentWire.Hooks.hook(:post_tool_use, fn ctx ->
        IO.inspect(ctx.tool_name, label: "Tool used")
        :ok
      end)

  """
  @spec hook(hook_event(), hook_callback()) :: hook_def()
  def hook(event, callback) when is_atom(event) and is_function(callback, 1) do
    :agent_wire_hooks.hook(event, callback)
  end

  @doc """
  Create a hook with a matcher filter.

  The matcher's `:tool_name` (exact or regex pattern) restricts which
  tools trigger the hook. The regex is pre-compiled at registration
  time. Invalid patterns crash immediately (fail-fast).

  ## Examples

      # Only fire for Bash tool
      AgentWire.Hooks.hook(:pre_tool_use, callback, %{tool_name: "Bash"})

      # Regex: fire for any Read* tool
      AgentWire.Hooks.hook(:pre_tool_use, callback, %{tool_name: "Read.*"})

  """
  @spec hook(hook_event(), hook_callback(), hook_matcher()) :: hook_def()
  def hook(event, callback, matcher)
      when is_atom(event) and is_function(callback, 1) and is_map(matcher) do
    :agent_wire_hooks.hook(event, callback, matcher)
  end

  # -------------------------------------------------------------------
  # Registry Management
  # -------------------------------------------------------------------

  @doc """
  Create an empty hook registry.
  """
  @spec new_registry() :: hook_registry()
  def new_registry, do: :agent_wire_hooks.new_registry()

  @doc """
  Register a single hook in the registry.

  ## Examples

      registry =
        AgentWire.Hooks.new_registry()
        |> AgentWire.Hooks.register_hook(hook)

  """
  @spec register_hook(hook_registry(), hook_def()) :: hook_registry()
  def register_hook(registry, hook_def) do
    :agent_wire_hooks.register_hook(hook_def, registry)
  end

  @doc """
  Register multiple hooks in the registry.
  """
  @spec register_hooks(hook_registry(), [hook_def()]) :: hook_registry()
  def register_hooks(registry, hooks) when is_list(hooks) do
    :agent_wire_hooks.register_hooks(hooks, registry)
  end

  @doc """
  Build a hook registry from a list of hook definitions.

  Returns `nil` when no hooks are configured (empty list or `nil`).
  This is the convenience function used by all adapter session modules.

  ## Examples

      registry = AgentWire.Hooks.build_registry([hook1, hook2])

  """
  @spec build_registry([hook_def()] | nil) :: hook_registry() | nil
  def build_registry(nil), do: nil

  def build_registry(hooks) when is_list(hooks) do
    case :agent_wire_hooks.build_registry(hooks) do
      :undefined -> nil
      registry -> registry
    end
  end

  # -------------------------------------------------------------------
  # Dispatch
  # -------------------------------------------------------------------

  @doc """
  Fire all hooks registered for an event.

  For **blocking** events (`:pre_tool_use`, `:user_prompt_submit`):
  returns `{:deny, reason}` on first deny, stopping iteration.

  For **notification** events: always returns `:ok` regardless
  of callback returns.

  Handles `nil` registry gracefully (returns `:ok`).

  ## Examples

      :ok = AgentWire.Hooks.fire(:post_tool_use, context, registry)

      case AgentWire.Hooks.fire(:pre_tool_use, context, registry) do
        :ok -> proceed()
        {:deny, reason} -> deny(reason)
      end

  """
  @spec fire(hook_event(), hook_context(), hook_registry() | nil) ::
          :ok | {:deny, binary()}
  def fire(event, context, nil) do
    :agent_wire_hooks.fire(event, context, :undefined)
  end

  def fire(event, context, registry) when is_map(registry) do
    :agent_wire_hooks.fire(event, context, registry)
  end
end
