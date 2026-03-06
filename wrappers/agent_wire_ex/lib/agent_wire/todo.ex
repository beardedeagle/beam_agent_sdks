defmodule AgentWire.Todo do
  @moduledoc """
  Todo tracking helpers for agent message streams.

  The Claude Code CLI uses the `TodoWrite` tool internally to track
  multi-step task progress. Each todo item has a content description,
  status (pending | in_progress | completed), and an optional activeForm
  for display during execution.

  This module provides convenience functions for extracting and
  querying todo state from agent message streams. Useful for:

    - Building progress indicators in client applications
    - Monitoring multi-step task completion
    - Extracting structured task breakdowns from agent responses

  ## Usage

      {:ok, messages} = ClaudeEx.query(session, "Build a REST API")
      todos = AgentWire.Todo.extract_todos(messages)
      completed = AgentWire.Todo.filter_by_status(todos, :completed)
      IO.puts("\#{length(completed)}/\#{length(todos)} tasks complete")

  ## Summary

      summary = AgentWire.Todo.todo_summary(todos)
      #=> %{pending: 2, in_progress: 1, completed: 3, total: 6}

  """

  @typedoc """
  Todo item status.
  """
  @type todo_status :: :pending | :in_progress | :completed

  @typedoc """
  A single todo item extracted from a TodoWrite tool use block.
  """
  @type todo_item :: %{
          required(:content) => binary(),
          required(:status) => todo_status(),
          optional(:active_form) => binary()
        }

  @doc """
  Extract all TodoWrite tool use blocks from a list of messages.

  Scans assistant messages for tool_use content blocks where the
  tool name is `TodoWrite`. Returns a flat list of todo items.

  ## Examples

      todos = AgentWire.Todo.extract_todos(messages)
      Enum.each(todos, fn %{content: c, status: s} ->
        IO.puts("[\#{s}] \#{c}")
      end)

  """
  @spec extract_todos([AgentWire.message()]) :: [todo_item()]
  def extract_todos(messages) when is_list(messages) do
    :agent_wire_todo.extract_todos(messages)
  end

  @doc """
  Filter todo items by status.

  ## Examples

      pending = AgentWire.Todo.filter_by_status(todos, :pending)
      done = AgentWire.Todo.filter_by_status(todos, :completed)

  """
  @spec filter_by_status([todo_item()], todo_status()) :: [todo_item()]
  def filter_by_status(todos, status)
      when is_list(todos) and status in [:pending, :in_progress, :completed] do
    :agent_wire_todo.filter_by_status(todos, status)
  end

  @doc """
  Return a summary map of todo counts by status.

  ## Examples

      AgentWire.Todo.todo_summary(todos)
      #=> %{pending: 2, in_progress: 1, completed: 3, total: 6}

  """
  @spec todo_summary([todo_item()]) :: %{atom() => non_neg_integer()}
  def todo_summary(todos) when is_list(todos) do
    :agent_wire_todo.todo_summary(todos)
  end
end
