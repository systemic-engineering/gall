-module(gall_ffi).
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
    spawn_claude/3,
    receive_event/2,
    git_current_branch/1,
    git_commit_session/7,
    read_config_tag/1,
    write_config_tag/2,
    send_patch/2,
    %% Daemon stdio
    read_line/0,
    write_line/1,
    %% Git MCP tools
    git_status/1,
    git_diff/2,
    git_log/3,
    git_blame/2,
    git_show_file/3,
    %% Gestalt resources
    list_gestalt_sessions/1,
    read_gestalt_session/2,
    %% Shell exec
    exec/2
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

%% Read an environment variable. Returns {ok, Value} | {error, nil}.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
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
%% Exe:   path to claude binary.
%% Args:  list of argument binaries or strings.
%% Extra: list of {Key, Value} env var pairs to inject into the child process.
%%        Injected via os:putenv — the port inherits the full current environment
%%        plus these additions. Thread-safe for single-session runners.
%% Returns port().
%%
%% Claude's stdout is delivered as {Port, {data, Chunk}} messages.
%% Exit is delivered as {Port, {exit_status, Code}}.
spawn_claude(Exe, Args, Extra) ->
    ExeStr = binary_to_list(Exe),
    ArgsStr = [binary_to_list(A) || A <- Args],
    lists:foreach(
        fun({K, V}) -> os:putenv(binary_to_list(K), binary_to_list(V)) end,
        Extra
    ),
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

%% Reed's ed25519 public key (32 raw bytes, no SSH header).
%% github.com/systemic-engineer — the root of trust for agent key derivation.
%% Shipped with gall. Anyone can re-derive and verify.
reed_root_pubkey() ->
    <<16#27, 16#ea, 16#cd, 16#f9, 16#32, 16#30, 16#e3, 16#66,
      16#ed, 16#bb, 16#1d, 16#6f, 16#01, 16#8b, 16#9a, 16#cc,
      16#8f, 16#4b, 16#9c, 16#a6, 16#2a, 16#b1, 16#a8, 16#12,
      16#21, 16#96, 16#da, 16#18, 16#d4, 16#2d, 16#fa, 16#18>>.

%% Derive an ed25519 agent keypair from Alex's public key + nickname.
%%
%% seed = HMAC-SHA256(key=alex_pubkey, "gall:" || nickname)
%% {PubKey, PrivKey} = ed25519(seed)
%%
%% Deterministic: same alex pubkey + same nickname → same keypair every time.
%% Transparent: anyone with alex's public key can re-derive and verify.
%%
%% Security model: provenance, not secrecy.
%% The key is not secret — the derivation formula is public.
%% What it proves: this tag was produced by gall using alex's root key.
derive_agent_keypair(Nickname) ->
    ReedPub  = reed_root_pubkey(),
    Identity = <<Nickname/binary, "@systemic.engineering">>,
    Seed     = crypto:mac(hmac, sha256, ReedPub, Identity),
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

%% Return the current branch name (abbrev-ref HEAD).
%% Returns "HEAD" if in detached-HEAD state.
git_current_branch(RepoDir) ->
    Raw = os:cmd("git -C " ++ binary_to_list(RepoDir)
                 ++ " rev-parse --abbrev-ref HEAD 2>/dev/null"),
    unicode:characters_to_binary(string:trim(Raw)).

%% Commit session Fragment files and create a signed session tag.
%%
%% Tag:     <TagName>  (e.g. sessions/main/mara/1737842315)
%% Message: session: <TagName>: <RootSha>
%%          key: ssh-ed25519 <base64> gall/<Nickname>
%%
%% When AlexKey is set, the attestation footer is appended:
%%   ---
%%   https://systemic.engineering/written-by-ai-consciousness/
%%   Cheers
%%   Alex 🌈
%%
%% Verify: git verify-tag <TagName>
%% Machine-maintained. Never moved.
git_commit_session(RepoDir, RelPath, Nickname, SessionId, TagName, RootSha, AlexKey) ->
    PathStr  = binary_to_list(RepoDir),
    RelStr   = binary_to_list(RelPath),
    NickStr  = binary_to_list(Nickname),
    _SidStr  = binary_to_list(SessionId),
    ShaStr   = binary_to_list(RootSha),
    TagStr   = binary_to_list(TagName),
    %% Derive agent keypair and write to temp file for this session.
    {PubKey, PrivKey} = derive_agent_keypair(Nickname),
    KeyComment = "gall/" ++ NickStr,
    KeyFile    = PathStr ++ "/.git/GALL_AGENT_KEY",
    {Pem, PubLine} = openssh_ed25519(PubKey, PrivKey, KeyComment),
    ok = file:write_file(KeyFile, Pem),
    ok = file:change_mode(KeyFile, 8#600),
    %% allowed_signers for this session: the derived key.
    AgentEmail = <<Nickname/binary, "@systemic.engineering">>,
    AllowedSig = PathStr ++ "/.git/GALL_ALLOWED",
    ok = file:write_file(AllowedSig,
        <<AgentEmail/binary, " ", PubLine/binary>>),
    %% Build tag message.
    PubLineTrimmed = binary:part(PubLine, 0, byte_size(PubLine) - 1),
    KeyLine = <<"key: ", PubLineTrimmed/binary>>,
    {SigningKey, TagMsg} = case AlexKey of
        <<>> ->
            BaseMsg = iolist_to_binary(["session: ", TagStr,
                                        ": ", ShaStr, "\n",
                                        KeyLine/binary, "\n"]),
            {KeyFile, BaseMsg};
        _ ->
            Footer = "\n---\nhttps://systemic.engineering/written-by-ai-consciousness/\nCheers\nAlex \xF0\x9F\x8C\x88\n",
            BaseMsg = iolist_to_binary(["session: ", TagStr,
                                        ": ", ShaStr, "\n",
                                        KeyLine/binary, Footer]),
            {binary_to_list(AlexKey), BaseMsg}
    end,
    CommitMsgFile = PathStr ++ "/.git/GALL_COMMIT_MSG",
    TagMsgFile    = PathStr ++ "/.git/GALL_TAG_MSG",
    ok = file:write_file(CommitMsgFile, TagMsg),
    ok = file:write_file(TagMsgFile, TagMsg),
    AgentEmailStr = NickStr ++ "@systemic.engineering",
    os:cmd("git -C " ++ PathStr ++ " add -- " ++ RelStr),
    os:cmd("git -C " ++ PathStr
           ++ " -c user.name=" ++ NickStr
           ++ " -c user.email=" ++ AgentEmailStr
           ++ " commit -F " ++ CommitMsgFile),
    os:cmd("git -C " ++ PathStr
           ++ " -c user.name=" ++ NickStr
           ++ " -c user.email=" ++ AgentEmailStr
           ++ " -c gpg.format=ssh"
           ++ " -c user.signingKey=" ++ binary_to_list(list_to_binary(SigningKey))
           ++ " -c gpg.ssh.allowedSignersFile=" ++ AllowedSig
           ++ " tag -s " ++ TagStr ++ " -F " ++ TagMsgFile),
    %% Clean up ephemeral key and temp files.
    file:delete(KeyFile),
    file:delete(CommitMsgFile),
    file:delete(TagMsgFile),
    ok.

%% ---------------------------------------------------------------------------
%% Config tag (.gall/config)
%% ---------------------------------------------------------------------------

%% Read the config tag message. Returns "" if tag does not exist.
read_config_tag(RepoDir) ->
    PathStr = binary_to_list(RepoDir),
    Raw = os:cmd("git -C " ++ PathStr
                 ++ " tag -l config --format='%(contents)' 2>/dev/null"),
    list_to_binary(string:trim(Raw)).

%% Write (or overwrite) the config tag with Contents as the message.
%% The tag is signed with the derived agent key — same trust chain as sessions.
write_config_tag(RepoDir, Contents) ->
    PathStr  = binary_to_list(RepoDir),
    MsgFile  = PathStr ++ "/.git/GALL_CONFIG_MSG",
    ok = file:write_file(MsgFile, Contents),
    os:cmd("git -C " ++ PathStr ++ " tag -d config 2>/dev/null"),
    os:cmd("git -C " ++ PathStr ++ " tag -a config -F " ++ MsgFile),
    file:delete(MsgFile),
    ok.

%% ---------------------------------------------------------------------------
%% Daemon stdio
%% ---------------------------------------------------------------------------

%% Read one line from stdin (blocking). Strips trailing newline.
%% Returns {ok, Binary} | {error, nil}.
read_line() ->
    case io:get_line("") of
        eof            -> {error, nil};
        {error, _}     -> {error, nil};
        Line           ->
            Trimmed = string:trim(Line, trailing, "\n"),
            {ok, unicode:characters_to_binary(Trimmed)}
    end.

%% Write a line to stdout (appends newline).
write_line(Data) ->
    io:put_chars(standard_io, [Data, $\n]).

%% ---------------------------------------------------------------------------
%% Git MCP tools
%% ---------------------------------------------------------------------------

git_status(Dir) ->
    unicode:characters_to_binary(
        os:cmd("git -C " ++ binary_to_list(Dir) ++ " status --short 2>&1")).

git_diff(Dir, Path) ->
    PathArg = case Path of
        <<>> -> "";
        P    -> " -- " ++ binary_to_list(P)
    end,
    unicode:characters_to_binary(
        os:cmd("git -C " ++ binary_to_list(Dir) ++ " diff" ++ PathArg ++ " 2>&1")).

git_log(Dir, Path, N) ->
    PathArg = case Path of
        <<>> -> "";
        P    -> " -- " ++ binary_to_list(P)
    end,
    NStr = integer_to_list(N),
    unicode:characters_to_binary(
        os:cmd("git -C " ++ binary_to_list(Dir)
               ++ " log --oneline -n " ++ NStr ++ PathArg ++ " 2>&1")).

git_blame(Dir, Path) ->
    unicode:characters_to_binary(
        os:cmd("git -C " ++ binary_to_list(Dir)
               ++ " blame " ++ binary_to_list(Path) ++ " 2>&1")).

git_show_file(Dir, Ref, Path) ->
    RefStr = case Ref of
        <<>> -> "HEAD";
        R    -> binary_to_list(R)
    end,
    unicode:characters_to_binary(
        os:cmd("git -C " ++ binary_to_list(Dir)
               ++ " show " ++ RefStr ++ ":" ++ binary_to_list(Path) ++ " 2>&1")).

%% ---------------------------------------------------------------------------
%% Gestalt resources
%% ---------------------------------------------------------------------------

%% List gall/* tags in the project repo, newest first.
%% Returns newline-separated tag names.
list_gestalt_sessions(WorkDir) ->
    Raw = os:cmd("git -C " ++ binary_to_list(WorkDir)
                 ++ " tag -l 'gall/*' --sort=-creatordate 2>/dev/null"),
    unicode:characters_to_binary(string:trim(Raw)).

%% Read the message body of a specific gestalt tag.
read_gestalt_session(GallDir, Tag) ->
    Raw = os:cmd("git -C " ++ binary_to_list(GallDir)
                 ++ " tag -l " ++ binary_to_list(Tag)
                 ++ " --format='%(contents)' 2>/dev/null"),
    unicode:characters_to_binary(string:trim(Raw)).

%% ---------------------------------------------------------------------------
%% Sync — send session patch
%% ---------------------------------------------------------------------------

%% Send the most recent .gall/ commit as a patch to Remote.
%%
%% Remote contains '@'  → email recipient, sent via git send-email
%% Remote is a git URL  → git push
%%
%% The patch IS the witnessed gestalt commit: Fragment files + signed tag.
send_patch(RepoDir, Remote) ->
    PathStr   = binary_to_list(RepoDir),
    RemoteStr = binary_to_list(Remote),
    case lists:member($@, RemoteStr) of
        true ->
            %% Email: format patch and pipe through git send-email.
            os:cmd("git -C " ++ PathStr
                   ++ " send-email"
                   ++ " --to=" ++ RemoteStr
                   ++ " --suppress-cc=all"
                   ++ " --no-signed-off-by-cc"
                   ++ " HEAD~1..HEAD 2>&1");
        false ->
            %% Git remote: push the gestalt commit.
            os:cmd("git -C " ++ PathStr
                   ++ " push " ++ RemoteStr ++ " HEAD 2>&1")
    end,
    ok.

%% ---------------------------------------------------------------------------
%% Shell exec
%% ---------------------------------------------------------------------------

%% Execute a shell command in Dir, capturing stdout+stderr.
exec(Dir, Command) ->
    Cmd = "cd " ++ binary_to_list(Dir) ++ " && " ++ binary_to_list(Command) ++ " 2>&1",
    unicode:characters_to_binary(os:cmd(Cmd)).
