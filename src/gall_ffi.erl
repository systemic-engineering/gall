-module(gall_ffi).
-export([now/0, read_line/0, write_line/1, keygen/1, get_env/1]).

now() -> os:system_time(second).

%% Read one line from stdin. Returns {ok, Line} or eof.
read_line() ->
    case io:get_line("") of
        eof -> eof;
        {error, _} -> eof;
        Line ->
            Trimmed = string:trim(Line, trailing, "\n\r"),
            {ok, unicode:characters_to_binary(Trimmed)}
    end.

%% Write a line to stdout. MCP is newline-framed.
write_line(Line) ->
    io:put_chars([Line, "\n"]).

%% Generate an ed25519 keypair at Path (no passphrase).
%% Path: ".gall/<nickname>/ssh/id_ed25519"
%% Creates parent directories as needed.
%% Returns {ok, PubKeyBinary} | {error, Reason}.
keygen(Path) ->
    PathStr = binary_to_list(Path),
    Dir = filename:dirname(PathStr),
    ok = filelib:ensure_dir(PathStr),
    _ = file:make_dir(Dir),
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

%% Read an environment variable. Returns {ok, Value} | error.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> error;
        Val -> {ok, unicode:characters_to_binary(Val)}
    end.
