/// Thin thoas wrapper for JSON decode/encode.
/// thoas is a pure-Erlang JSON library — no Gleam version coupling.
import gleam/dynamic.{type Dynamic}

@external(erlang, "gall_json_ffi", "decode")
pub fn decode(json: String) -> Result(Dynamic, String)

@external(erlang, "gall_json_ffi", "encode")
pub fn encode(value: Dynamic) -> String

@external(erlang, "gall_json_ffi", "get_string")
pub fn get_string(obj: Dynamic, key: String) -> Result(String, Nil)

@external(erlang, "gall_json_ffi", "get_list")
pub fn get_list(obj: Dynamic, key: String) -> Result(List(String), Nil)
