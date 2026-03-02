-module(gall_trace_ffi).
-export([execute/3]).

%% Telemetry emission. Attempts to call telemetry:execute/3 if the
%% telemetry application is available. Falls back to a no-op.
%%
%% Event: list of binaries (e.g. [<<"gall">>, <<"tool">>, <<"call">>])
%% Name: tool name binary
%% Meta: Gleam Metadata record (opaque — passed through to telemetry as-is)

execute(Event, Name, Meta) ->
    EventAtoms = [binary_to_atom(E, utf8) || E <- Event],
    Measurements = #{tool => Name},
    Metadata = #{meta => Meta},
    try
        telemetry:execute(EventAtoms, Measurements, Metadata)
    catch
        error:undef -> ok;
        error:_ -> ok
    end,
    nil.
