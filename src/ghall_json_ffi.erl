-module(ghall_json_ffi).
-export([decode/1, encode/1, get_string/2, get_list/2]).

%% Decode a JSON string. Returns {ok, Value} | {error, Reason}.
decode(Json) ->
    case thoas:decode(Json) of
        {ok, Value} -> {ok, Value};
        {error, Err} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Err]))}
    end.

%% Encode an Erlang term to JSON binary.
encode(Value) ->
    thoas:encode(Value).

%% Extract a string field from a decoded JSON object (map).
get_string(Obj, Key) when is_map(Obj) ->
    KeyBin = unicode:characters_to_binary(Key),
    case maps:find(KeyBin, Obj) of
        {ok, Val} when is_binary(Val) -> {ok, Val};
        _ -> error
    end;
get_string(_, _) -> error.

%% Extract a list of strings from a decoded JSON object.
get_list(Obj, Key) when is_map(Obj) ->
    KeyBin = unicode:characters_to_binary(Key),
    case maps:find(KeyBin, Obj) of
        {ok, List} when is_list(List) ->
            Strings = [S || S <- List, is_binary(S)],
            {ok, Strings};
        _ -> error
    end;
get_list(_, _) -> error.
