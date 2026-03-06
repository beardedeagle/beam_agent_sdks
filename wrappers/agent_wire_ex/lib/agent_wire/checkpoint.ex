defmodule AgentWire.Checkpoint do
  @moduledoc """
  File checkpointing and rewind for agent sessions.

  Provides snapshot and restore capabilities so that file mutations
  made by tools can be reversed. Before a tool writes or edits files,
  callers snapshot the target paths. Rewind restores files to their
  checkpointed state.

  Uses ETS for checkpoint metadata and stores file content directly.
  Checkpoints persist for the lifetime of the BEAM node (or until
  explicitly deleted/cleared).

  ## Usage

      # Snapshot files before a mutation
      {:ok, checkpoint} = AgentWire.Checkpoint.snapshot(session_id, uuid, ["/tmp/foo.txt"])

      # Later, rewind to that checkpoint
      :ok = AgentWire.Checkpoint.rewind(session_id, uuid)

  ## Listing & Cleanup

      {:ok, checkpoints} = AgentWire.Checkpoint.list_checkpoints(session_id)
      :ok = AgentWire.Checkpoint.delete_checkpoint(session_id, uuid)
      :ok = AgentWire.Checkpoint.clear()

  """

  @typedoc "A single file's snapshot."
  @type file_snapshot :: %{
          required(:path) => binary(),
          required(:content) => binary() | nil,
          required(:existed) => boolean(),
          required(:permissions) => non_neg_integer() | nil
        }

  @typedoc "Checkpoint metadata stored in ETS."
  @type checkpoint :: %{
          required(:uuid) => binary(),
          required(:session_id) => binary(),
          required(:created_at) => integer(),
          required(:files) => [file_snapshot()]
        }

  @doc """
  Ensure the checkpoints ETS table exists. Idempotent.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    :agent_wire_checkpoint.ensure_table()
  end

  @doc """
  Clear all checkpoint data.
  """
  @spec clear() :: :ok
  def clear do
    :agent_wire_checkpoint.clear()
  end

  @doc """
  Snapshot a list of file paths for later rewind.

  Reads each file's content and permissions. Files that don't exist
  are recorded as non-existent (rewind will delete them).

  ## Examples

      {:ok, cp} = AgentWire.Checkpoint.snapshot("sess_1", "uuid_1", ["/tmp/a.txt"])
      cp.files  #=> [%{path: "/tmp/a.txt", content: "...", existed: true, ...}]

  """
  @spec snapshot(binary(), binary(), [binary() | charlist()]) :: {:ok, checkpoint()}
  def snapshot(session_id, uuid, file_paths)
      when is_binary(session_id) and is_binary(uuid) and is_list(file_paths) do
    :agent_wire_checkpoint.snapshot(session_id, uuid, file_paths)
  end

  @doc """
  Rewind files to a checkpoint state.

  Restores each file's content, permissions, and existence. Files
  created after the checkpoint are deleted if they didn't exist at
  checkpoint time.

  ## Examples

      :ok = AgentWire.Checkpoint.rewind("sess_1", "uuid_1")

  """
  @spec rewind(binary(), binary()) :: :ok | {:error, :not_found | term()}
  def rewind(session_id, uuid)
      when is_binary(session_id) and is_binary(uuid) do
    :agent_wire_checkpoint.rewind(session_id, uuid)
  end

  @doc """
  List all checkpoints for a session, newest first.
  """
  @spec list_checkpoints(binary()) :: {:ok, [checkpoint()]}
  def list_checkpoints(session_id) when is_binary(session_id) do
    :agent_wire_checkpoint.list_checkpoints(session_id)
  end

  @doc """
  Get a specific checkpoint by session ID and UUID.
  """
  @spec get_checkpoint(binary(), binary()) :: {:ok, checkpoint()} | {:error, :not_found}
  def get_checkpoint(session_id, uuid)
      when is_binary(session_id) and is_binary(uuid) do
    :agent_wire_checkpoint.get_checkpoint(session_id, uuid)
  end

  @doc """
  Delete a checkpoint.
  """
  @spec delete_checkpoint(binary(), binary()) :: :ok
  def delete_checkpoint(session_id, uuid)
      when is_binary(session_id) and is_binary(uuid) do
    :agent_wire_checkpoint.delete_checkpoint(session_id, uuid)
  end

  @doc """
  Extract file paths from a tool use message for checkpointing.

  Inspects the tool name and input to determine which files will
  be modified. Recognizes `Write`, `Edit`, `write`, and `edit` tools.

  ## Examples

      AgentWire.Checkpoint.extract_file_paths("Write", %{"file_path" => "/tmp/a.txt"})
      #=> ["/tmp/a.txt"]

      AgentWire.Checkpoint.extract_file_paths("Grep", %{})
      #=> []

  """
  @spec extract_file_paths(binary(), map()) :: [binary()]
  def extract_file_paths(tool_name, tool_input) when is_map(tool_input) do
    :agent_wire_checkpoint.extract_file_paths(tool_name, tool_input)
  end
end
