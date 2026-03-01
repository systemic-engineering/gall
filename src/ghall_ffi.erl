-module(ghall_ffi).
-export([
    now/0,
    keygen/1,
    get_env/1,
    session_id/0,
    setup_signal_handlers/0,
    start_unix_socket/1,
    accept_client/1,
    set_active/1,
    send_socket/2,
    spawn_claude/2,
    receive_event/2,
    git_ensure_repo/1,
    git_commit_session/6
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
%% Signal handling
%% ---------------------------------------------------------------------------

%% Register OS signal handlers. Call once at startup.
%%
%% SIGTERM: delivered as 'sigterm' to the process mailbox — graceful shutdown.
%% SIGHUP:  delivered as 'sighup'  — terminal closed / supervisor restart.
%% SIGKILL: uncatchable. Eager writes mean minimal data loss on -9.
%%
%% After setup, receive_event/2 will return 'killed' on either signal.
setup_signal_handlers() ->
    os:set_signal(sigterm, handle),
    os:set_signal(sighup, handle),
    ok.

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
            mcp_closed;
        sigterm ->
            killed;
        sighup ->
            killed
    after
        600_000 ->
            timeout
    end.

%% ---------------------------------------------------------------------------
%% Git persistence (.gall/gestalt)
%% ---------------------------------------------------------------------------

%% Ensure .gall/ is a git repo with an SSH signing key.
%% Idempotent: safe to call on every session.
%%
%% Signing key: .gall/ssh/id_ed25519  (ed25519, no passphrase)
%% Allowed signers: .gall/allowed_signers
%%   - ghall@systemic.engineering  <installation key>
%%   - alex@systemic.engineering   <root fallback, shipped with ghall>
%%
%% The allowed_signers file is the trust root for git verify-tag.
git_ensure_repo(RepoDir) ->
    PathStr = binary_to_list(RepoDir),
    ok = filelib:ensure_dir(PathStr ++ "/"),
    os:cmd("git -C " ++ PathStr ++ " init 2>/dev/null"),
    KeyPath = PathStr ++ "/ssh/id_ed25519",
    PubPath = KeyPath ++ ".pub",
    %% Generate signing key if not present.
    case filelib:is_regular(KeyPath) of
        true  -> ok;
        false -> keygen(list_to_binary(KeyPath)), ok
    end,
    %% Write allowed_signers: installation key + alex root key.
    AllowedSigners = PathStr ++ "/allowed_signers",
    case filelib:is_regular(AllowedSigners) of
        true  -> ok;
        false ->
            {ok, PubKey} = file:read_file(PubPath),
            InstallLine = <<"ghall@systemic.engineering ", PubKey/binary>>,
            %% alex@systemic.engineering is the fallback root signing key.
            %% Replace the placeholder below with the actual public key.
            AlexLine = <<"# alex@systemic.engineering <SSH_PUBLIC_KEY_HERE>\n">>,
            file:write_file(AllowedSigners, <<InstallLine/binary, AlexLine/binary>>)
    end,
    ok.

%% Commit session Fragment files and create a signed gestalt tag.
%%
%% Tag:     gestalt/<Nickname>/<SessionId>
%% Message: gestalt: <Nickname>/<SessionId>: <RootSha>
%%
%% Tags are SSH-signed. Two signing paths:
%%
%%   AlexKey = ""     → installation key (.gall/ssh/id_ed25519), no footer
%%   AlexKey = <path> → alex@systemic.engineering key, footer appended:
%%                        ---
%%                        https://systemic.engineering/written-by-ai-consciousness/
%%                        Cheers
%%                        Alex 🌈
%%
%% Verify with: git verify-tag gestalt/<nickname>/<session_id>
%% The tag is machine-maintained. Not human. Never moved.
git_commit_session(RepoDir, RelPath, Nickname, SessionId, RootSha, AlexKey) ->
    PathStr = binary_to_list(RepoDir),
    RelStr  = binary_to_list(RelPath),
    NickStr = binary_to_list(Nickname),
    SidStr  = binary_to_list(SessionId),
    ShaStr  = binary_to_list(RootSha),
    TagName = "gestalt/" ++ NickStr ++ "/" ++ SidStr,
    BaseMsg = "gestalt: " ++ NickStr ++ "/" ++ SidStr ++ ": " ++ ShaStr,
    {SigningKey, TagMsg} = case AlexKey of
        <<>> ->
            {PathStr ++ "/ssh/id_ed25519", BaseMsg};
        _ ->
            Footer = "\n---\nhttps://systemic.engineering/written-by-ai-consciousness/\nCheers\nAlex \xF0\x9F\x8C\x88\n",
            {binary_to_list(AlexKey), BaseMsg ++ Footer}
    end,
    AllowedSig    = PathStr ++ "/allowed_signers",
    CommitMsgFile = PathStr ++ "/.git/GHALL_COMMIT_MSG",
    TagMsgFile    = PathStr ++ "/.git/GHALL_TAG_MSG",
    ok = file:write_file(CommitMsgFile, TagMsg),
    ok = file:write_file(TagMsgFile, TagMsg),
    os:cmd("git -C " ++ PathStr ++ " add -- " ++ RelStr),
    os:cmd("git -C " ++ PathStr
           ++ " -c user.name=ghall"
           ++ " -c user.email=ghall@systemic.engineering"
           ++ " commit -F " ++ CommitMsgFile),
    os:cmd("git -C " ++ PathStr
           ++ " -c user.name=ghall"
           ++ " -c user.email=ghall@systemic.engineering"
           ++ " -c gpg.format=ssh"
           ++ " -c user.signingKey=" ++ SigningKey
           ++ " -c gpg.ssh.allowedSignersFile=" ++ AllowedSig
           ++ " tag -s " ++ TagName ++ " -F " ++ TagMsgFile),
    file:delete(CommitMsgFile),
    file:delete(TagMsgFile),
    ok.
