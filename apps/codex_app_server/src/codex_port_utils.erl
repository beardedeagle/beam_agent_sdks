-module(codex_port_utils).

-moduledoc """
Shared utility functions for Codex port-based adapters.

Extracts common buffer management, port operations, and registry
building used by both `codex_session` and `codex_exec` `gen_statem`
modules. Pure functions -- no processes, no state.
""".

-export([
    buffer_line/3,
    append_buffer/3,
    check_buffer_overflow/2,
    close_port/1
]).

%%====================================================================
%% Buffer Management
%%====================================================================

-doc "Append a complete line (with trailing newline) to the buffer. Returns the updated buffer, truncated to empty if overflow.".
-spec buffer_line(binary(), binary(), pos_integer()) -> binary().
buffer_line(Line, Buffer, BufferMax) ->
    check_buffer_overflow(<<Buffer/binary, Line/binary, "\n">>, BufferMax).

-doc "Append a partial (incomplete line) to the buffer. Returns the updated buffer, truncated to empty if overflow.".
-spec append_buffer(binary(), binary(), pos_integer()) -> binary().
append_buffer(Partial, Buffer, BufferMax) ->
    check_buffer_overflow(<<Buffer/binary, Partial/binary>>, BufferMax).

-doc "Check buffer size against limit; truncate with warning if over.".
-spec check_buffer_overflow(binary(), pos_integer()) -> binary().
check_buffer_overflow(Buffer, BufferMax) ->
    case byte_size(Buffer) > BufferMax of
        true ->
            agent_wire_telemetry:buffer_overflow(byte_size(Buffer), BufferMax),
            logger:warning("Codex buffer overflow (~p bytes), truncating",
                           [byte_size(Buffer)]),
            <<>>;
        false ->
            Buffer
    end.

%%====================================================================
%% Port Operations
%%====================================================================

-doc "Safely close a port, handling undefined and already-closed ports.".
-spec close_port(port() | undefined) -> ok.
close_port(undefined) -> ok;
close_port(Port) ->
    try port_close(Port) catch error:_ -> ok end,
    ok.

