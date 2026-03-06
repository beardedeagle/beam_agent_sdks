defmodule AgentWire.TodoTest do
  use ExUnit.Case, async: true

  describe "extract_todos/1" do
    test "extracts TodoWrite blocks from assistant messages" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{
                "content" => "Build REST API",
                "status" => "pending"
              }
            },
            %{type: :text, text: "Working on it..."}
          ]
        },
        %{type: :text, content: "hello"}
      ]

      todos = AgentWire.Todo.extract_todos(messages)
      assert length(todos) == 1
      assert hd(todos).content == "Build REST API"
      assert hd(todos).status == :pending
    end

    test "extracts multiple todos from multiple messages" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{"content" => "Task 1", "status" => "completed"}
            }
          ]
        },
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{"content" => "Task 2", "status" => "in_progress"}
            },
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{"content" => "Task 3", "status" => "pending"}
            }
          ]
        }
      ]

      todos = AgentWire.Todo.extract_todos(messages)
      assert length(todos) == 3
      statuses = Enum.map(todos, & &1.status)
      assert statuses == [:completed, :in_progress, :pending]
    end

    test "returns empty list for messages without TodoWrite" do
      messages = [
        %{type: :text, content: "hello"},
        %{type: :result, content: "done"}
      ]

      assert AgentWire.Todo.extract_todos(messages) == []
    end

    test "returns empty list for empty messages" do
      assert AgentWire.Todo.extract_todos([]) == []
    end

    test "extracts active_form when present" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{
                "content" => "Step 1",
                "status" => "in_progress",
                "activeForm" => "Step 1 — Setting up..."
              }
            }
          ]
        }
      ]

      [todo] = AgentWire.Todo.extract_todos(messages)
      assert todo.active_form == "Step 1 — Setting up..."
    end

    test "uses subject field as fallback for content" do
      messages = [
        %{
          type: :assistant,
          content_blocks: [
            %{
              type: :tool_use,
              name: "TodoWrite",
              input: %{"subject" => "Fallback subject", "status" => "pending"}
            }
          ]
        }
      ]

      [todo] = AgentWire.Todo.extract_todos(messages)
      assert todo.content == "Fallback subject"
    end
  end

  describe "filter_by_status/2" do
    setup do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :in_progress},
        %{content: "C", status: :completed},
        %{content: "D", status: :pending}
      ]

      %{todos: todos}
    end

    test "filters pending", %{todos: todos} do
      result = AgentWire.Todo.filter_by_status(todos, :pending)
      assert length(result) == 2
      assert Enum.all?(result, &(&1.status == :pending))
    end

    test "filters in_progress", %{todos: todos} do
      result = AgentWire.Todo.filter_by_status(todos, :in_progress)
      assert length(result) == 1
      assert hd(result).content == "B"
    end

    test "filters completed", %{todos: todos} do
      result = AgentWire.Todo.filter_by_status(todos, :completed)
      assert length(result) == 1
      assert hd(result).content == "C"
    end

    test "returns empty for no matches" do
      todos = [%{content: "A", status: :pending}]
      assert AgentWire.Todo.filter_by_status(todos, :completed) == []
    end
  end

  describe "todo_summary/1" do
    test "counts by status" do
      todos = [
        %{content: "A", status: :pending},
        %{content: "B", status: :pending},
        %{content: "C", status: :in_progress},
        %{content: "D", status: :completed},
        %{content: "E", status: :completed},
        %{content: "F", status: :completed}
      ]

      summary = AgentWire.Todo.todo_summary(todos)
      assert summary.pending == 2
      assert summary.in_progress == 1
      assert summary.completed == 3
      assert summary.total == 6
    end

    test "handles empty list" do
      summary = AgentWire.Todo.todo_summary([])
      assert summary.total == 0
    end

    test "handles single status" do
      todos = [%{content: "A", status: :completed}]
      summary = AgentWire.Todo.todo_summary(todos)
      assert summary.completed == 1
      assert summary.total == 1
    end
  end
end
