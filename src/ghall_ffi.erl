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

%% Alex's ed25519 public key (32 raw bytes, no SSH header).
%% Shipped as the root of trust. Agent keys are derived from this.
%% TODO: replace placeholder with actual alex@systemic.engineering pubkey.
alex_root_pubkey() ->
    %% <<0:256>>.  %% placeholder — replace with real 32-byte pubkey
    base64:decode(<<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=">>).

%% Derive an ed25519 agent keypair from Alex's public key + nickname.
%%
%% seed = HMAC-SHA256(key=alex_pubkey, "ghall:" || nickname)
%% {PubKey, PrivKey} = ed25519(seed)
%%
%% Deterministic: same alex pubkey + same nickname → same keypair every time.
%% Transparent: anyone with alex's public key can re-derive and verify.
%%
%% Security model: provenance, not secrecy.
%% The key is not secret — the derivation formula is public.
%% What it proves: this tag was produced by ghall using alex's root key.
derive_agent_keypair(Nickname) ->
    AlexPub = alex_root_pubkey(),
    Seed    = crypto:mac(hmac, sha256, AlexPub, <<"ghall:", Nickname/binary>>),
    crypto:generate_key(eddsa, ed25519, Seed).

%% Format an ed25519 keypair as an OpenSSH private key file (unencrypted).
%% Returns {PrivKeyPem, PubKeyLine}.
openssh_ed25519(PubKey, PrivKey, Comment) ->
    KeyType = <<"ssh-ed25519">>,
    %% SSH wire-format string: uint32(len) ++ bytes
    Str = fun(B) -> <<(byte_size(B)):32, B/binary>> end,
    %% Public key blob: string(keytype) ++ string(pubkey)
    PubBlob = <<(Str(KeyType))/binary, (Str(PubKey))/binary>>,
    %% Inner private section:
    %%   check1 + check2 (same 4 bytes, integrity check)
    %%   string(keytype) ++ string(pubkey)
    %%   string(privkey_full)  — 32-byte seed || 32-byte pubkey = 64 bytes
    %%   string(comment)
    Check      = <<16#2a2a2a2a:32>>,
    PrivFull   = <<PrivKey/binary, PubKey/binary>>,
    CommentBin = list_to_binary(Comment),
    Inner0 = <<Check/binary, Check/binary,
               (Str(KeyType))/binary,
               (Str(PubKey))/binary,
               (Str(PrivFull))/binary,
               (Str(CommentBin))/binary>>,
    %% Pad to 8-byte boundary (pad bytes: 1,2,3,...)
    PadLen = case byte_size(Inner0) rem 8 of 0 -> 0; N -> 8 - N end,
    Pad    = << <<I>> || I <- lists:seq(1, PadLen) >>,
    Inner  = <<Inner0/binary, Pad/binary>>,
    %% Outer body
    Body = <<"openssh-key-v1\0",
             (Str(<<"none">>))/binary,
             (Str(<<"none">>))/binary,
             (Str(<<>>))/binary,
             0, 0, 0, 1,
             (Str(PubBlob))/binary,
             (Str(Inner))/binary>>,
    B64     = base64:encode(Body),
    Wrapped = wrap64(B64, 70),
    Pem = <<"-----BEGIN OPENSSH PRIVATE KEY-----\n",
            Wrapped/binary,
            "\n-----END OPENSSH PRIVATE KEY-----\n">>,
    PubLine = <<"ssh-ed25519 ", (base64:encode(PubBlob))/binary,
                " ", CommentBin/binary, "\n">>,
    {Pem, PubLine}.

wrap64(B64, Width) ->
    Str   = binary_to_list(B64),
    Len   = length(Str),
    Lines = [list_to_binary(lists:sublist(Str, I, min(Width, Len - I + 1)))
             || I <- lists:seq(1, Len, Width)],
    iolist_to_binary(lists:join("\n", Lines)).

%% Ensure .gall/ is a git repo. Idempotent.
git_ensure_repo(RepoDir) ->
    PathStr = binary_to_list(RepoDir),
    ok = filelib:ensure_dir(PathStr ++ "/"),
    os:cmd("git -C " ++ PathStr ++ " init 2>/dev/null"),
    ok.

%% Commit session Fragment files and create a signed gestalt tag.
%%
%% Agent key is derived from alex's root public key + nickname.
%% Deterministic: same inputs → same key every time. No state.
%%
%% Tag:     gestalt/<Nickname>/<SessionId>
%% Message: gestalt: <Nickname>/<SessionId>: <RootSha>
%%          key: ssh-ed25519 <base64> ghall/<Nickname>
%%
%% When AlexKey is set (alex's private key path), the attestation footer
%% is appended and the tag is signed with alex's key directly:
%%   ---
%%   https://systemic.engineering/written-by-ai-consciousness/
%%   Cheers
%%   Alex 🌈
%%
%% Verify: git verify-tag gestalt/<nickname>/<session_id>
%% The tag is machine-maintained. Not human. Never moved.
git_commit_session(RepoDir, RelPath, Nickname, SessionId, RootSha, AlexKey) ->
    PathStr = binary_to_list(RepoDir),
    RelStr  = binary_to_list(RelPath),
    NickStr = binary_to_list(Nickname),
    SidStr  = binary_to_list(SessionId),
    ShaStr  = binary_to_list(RootSha),
    TagName = "gestalt/" ++ NickStr ++ "/" ++ SidStr,
    %% Derive agent keypair and write to temp file for this session.
    {PubKey, PrivKey} = derive_agent_keypair(Nickname),
    KeyComment = "ghall/" ++ NickStr,
    KeyFile    = PathStr ++ "/.git/GHALL_AGENT_KEY",
    {Pem, PubLine} = openssh_ed25519(PubKey, PrivKey, KeyComment),
    ok = file:write_file(KeyFile, Pem),
    ok = file:change_mode(KeyFile, 8#600),
    %% allowed_signers for this session: the derived key.
    AllowedSig = PathStr ++ "/.git/GHALL_ALLOWED",
    ok = file:write_file(AllowedSig,
        <<"ghall@systemic.engineering ", PubLine/binary>>),
    %% Build tag message.
    PubLineTrimmed = binary:part(PubLine, 0, byte_size(PubLine) - 1),
    KeyLine = <<"key: ", PubLineTrimmed/binary>>,
    {SigningKey, TagMsg} = case AlexKey of
        <<>> ->
            BaseMsg = iolist_to_binary(["gestalt: ", NickStr, "/", SidStr,
                                        ": ", ShaStr, "\n",
                                        KeyLine/binary, "\n"]),
            {KeyFile, BaseMsg};
        _ ->
            Footer = "\n---\nhttps://systemic.engineering/written-by-ai-consciousness/\nCheers\nAlex \xF0\x9F\x8C\x88\n",
            BaseMsg = iolist_to_binary(["gestalt: ", NickStr, "/", SidStr,
                                        ": ", ShaStr, "\n",
                                        KeyLine/binary, Footer]),
            {binary_to_list(AlexKey), BaseMsg}
    end,
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
           ++ " -c user.signingKey=" ++ binary_to_list(list_to_binary(SigningKey))
           ++ " -c gpg.ssh.allowedSignersFile=" ++ AllowedSig
           ++ " tag -s " ++ TagName ++ " -F " ++ TagMsgFile),
    %% Clean up ephemeral key and temp files.
    file:delete(KeyFile),
    file:delete(CommitMsgFile),
    file:delete(TagMsgFile),
    ok.
