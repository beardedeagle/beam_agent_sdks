defmodule AgentWire.Command do
  @moduledoc """
  Universal command execution for agent sessions.

  Provides shell command execution across all adapters via Erlang ports.
  Any adapter can run commands regardless of whether the underlying CLI
  supports it natively.

  Uses `erlang:open_port/2` with `spawn_executable` for safe,
  timeout-aware, output-captured command execution.

  ## Usage

      {:ok, result} = AgentWire.Command.run("ls -la")
      result.exit_code  #=> 0
      result.output     #=> "total 42\\n..."

  ## Options

      {:ok, result} = AgentWire.Command.run("pwd", %{
        cwd: "/tmp",
        timeout: 5000,
        max_output: 1024
      })

  """

  @typedoc "Options for command execution."
  @type command_opts :: %{
          optional(:timeout) => pos_integer(),
          optional(:cwd) => binary() | charlist(),
          optional(:env) => [{charlist(), charlist()}],
          optional(:max_output) => pos_integer()
        }

  @typedoc "Result of command execution."
  @type command_result :: %{
          required(:exit_code) => integer(),
          required(:output) => binary()
        }

  @doc """
  Run a shell command with default options.

  Executes the command via the system shell (`sh -c` on Unix,
  `cmd /c` on Windows) with a 30-second timeout and 1MB output cap.

  ## Examples

      {:ok, %{exit_code: 0, output: output}} = AgentWire.Command.run("echo hello")
      output  #=> "hello\\n"

      {:ok, %{exit_code: 1}} = AgentWire.Command.run("false")

  """
  @spec run(binary() | charlist()) :: {:ok, command_result()} | {:error, term()}
  def run(command) do
    :agent_wire_command.run(command)
  end

  @doc """
  Run a shell command with options.

  ## Options

    * `:timeout` - Max execution time in ms (default: 30000)
    * `:cwd` - Working directory for the command
    * `:env` - Environment variables as `[{key, value}]` charlists
    * `:max_output` - Max bytes to capture (default: 1MB)

  ## Examples

      {:ok, result} = AgentWire.Command.run("pwd", %{cwd: "/tmp"})
      result.output  #=> "/tmp\\n"

      {:error, {:timeout, 100}} = AgentWire.Command.run("sleep 10", %{timeout: 100})

  """
  @spec run(binary() | charlist(), command_opts()) :: {:ok, command_result()} | {:error, term()}
  def run(command, opts) when is_map(opts) do
    :agent_wire_command.run(command, opts)
  end
end
