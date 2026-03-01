-module(gall_ffi).
-export([
    now/0,
    keygen/1,
    get_env/1,
    session_id/0,
    start_unix_socket/1,
    accept_client/1,
    set_active/1,
    send_socket/2,
    spawn_claude/2,
    receive_event/2
]).

%% ---------------------------------------------------------------------------
%% Time
%% ---------------------------------------------------------------------------

now() -> os:system_time(second).

session_id() ->
    Bin = integer_to_binary(os:system_time(millisecond)),
    Bin.

%% ---------------------------------------------------------------------------
%% Environment
%% ---------------------------------------------------------------------------

%% Read an environment variable. Returns {ok, Value} | error.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> error;
        Val -> {ok, unicode:characters_to_binary(Val)}
    end.

%% ---------------------------------------------------------------------------
%% SSH keygen
%% ---------------------------------------------------------------------------

%% Generate an ed25519 keypair at Path (no passphrase).
%% Path: ".gall/<nickname>/ssh/id_ed25519"
%% Creates parent directories as needed.
%% Returns {ok, PubKeyBinary} | {error, Reason}.
keygen(Path) ->
    PathStr = binary_to_list(Path),
    ok = filelib:ensure_dir(PathStr),
    Cmd = "ssh-keygen -t ed25519 -f " ++ PathStr ++ " -N '' -q 2>&1",
    case os:cmd(Cmd) of
        "" ->
            PubPath = PathStr ++ ".pub",
            case file:read_file(PubPath) of
                {ok, Pub} -> {ok, string:trim(Pub, trailing, "\n")};
                {error, R} -> {error, R}
            end;
        Output ->
            {error, unicode:characters_to_binary(Output)}
    end.

%% ---------------------------------------------------------------------------
%% Unix socket (MCP transport)
%% ---------------------------------------------------------------------------

%% Start a unix socket listener at Path.
%% Returns {ok, ListenSocket} | {error, Reason}.
%%
%% Uses {packet, line} so each recv delivers one newline-terminated JSON frame.
%% MCP protocol is newline-framed — this matches exactly.
start_unix_socket(Path) ->
    PathStr = binary_to_list(Path),
    %% Remove stale socket file if present.
    file:delete(PathStr),
    Options = [binary, {packet, line}, {active, false}, {reuseaddr, true}],
    gen_tcp:listen(0, [{ifaddr, {local, PathStr}} | Options]).

%% Wait for a client to connect (blocks up to 15 seconds).
%% Returns {ok, ConnSocket} | {error, Reason}.
accept_client(ListenSock) ->
    gen_tcp:accept(ListenSock, 15_000).

%% Set socket to active mode so messages arrive in process mailbox.
set_active(Sock) ->
    inet:setopts(Sock, [{active, true}]).

%% Send a newline-terminated JSON frame over the socket.
send_socket(Sock, Data) ->
    gen_tcp:send(Sock, [Data, "\n"]).

%% ---------------------------------------------------------------------------
%% Claude port (stdout capture)
%% ---------------------------------------------------------------------------

%% Spawn claude as an Erlang port.
%% Exe: path to claude binary.
%% Args: list of argument binaries or strings.
%% Returns port().
%%
%% Claude's stdout is delivered as {Port, {data, Chunk}} messages.
%% Exit is delivered as {Port, {exit_status, Code}}.
spawn_claude(Exe, Args) ->
    ExeStr = binary_to_list(Exe),
    ArgsStr = [binary_to_list(A) || A <- Args],
    open_port(
        {spawn_executable, ExeStr},
        [
            {args, ArgsStr},
            binary,
            stream,
            exit_status,
            use_stdio,
            stderr_to_stdout
        ]
    ).

%% ---------------------------------------------------------------------------
%% Event loop primitive
%% ---------------------------------------------------------------------------

%% Block until an event arrives from the claude port or MCP socket.
%% Returns one of:
%%   {thought, Data}   — chunk from claude stdout
%%   {exit, Code}      — claude process exited
%%   {mcp, Data}       — MCP JSON line from socket
%%   mcp_closed        — socket closed or error
%%   timeout           — 10 minute safety timeout
%%
%% Call in a tail-recursive Gleam loop to process all events.
receive_event(Port, Sock) ->
    receive
        {Port, {data, Data}} ->
            {thought, Data};
        {Port, {exit_status, Code}} ->
            {exit, Code};
        {tcp, Sock, Data} ->
            {mcp, Data};
        {tcp_closed, Sock} ->
            mcp_closed;
        {tcp_error, Sock, _Reason} ->
            mcp_closed
    after
        600_000 ->
            timeout
    end.
