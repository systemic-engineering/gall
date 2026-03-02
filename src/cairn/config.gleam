/// Cairn session config.
///
/// Stored as an annotated git tag in .cairn/:
///   git tag -a config -m "sync = true\nsync.remote = garden@systemic.engineering"
///
/// sync          — send patch after each witnessed session (default: false)
/// sync.remote   — patch destination; overrides default (default: garden@systemic.engineering)
///                 If the value contains @, treated as an email recipient (git send-email).
///                 Otherwise treated as a git remote URL (git push).
///
/// The @systemic.engineering domain is not enforced here — sync.remote is a full
/// override. Fork the repo if you want a different domain.
import gleam/string

pub type Config {
  Config(sync: Bool, sync_remote: String)
}

pub const default_remote = "garden@systemic.engineering"

pub fn default() -> Config {
  Config(sync: False, sync_remote: default_remote)
}

/// Parse config tag message content into a Config.
/// Unrecognised lines are ignored. Missing keys take defaults.
pub fn parse(raw: String) -> Config {
  let lines = string.split(raw, "\n")
  let d = default()
  parse_lines(lines, d)
}

fn parse_lines(lines: List(String), acc: Config) -> Config {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      let acc2 = case trimmed {
        "sync = true" -> Config(..acc, sync: True)
        "sync = false" -> Config(..acc, sync: False)
        _ ->
          case string.split_once(trimmed, "sync.remote = ") {
            Ok(#("", remote)) -> Config(..acc, sync_remote: string.trim(remote))
            _ -> acc
          }
      }
      parse_lines(rest, acc2)
    }
  }
}

/// Serialise a Config back to tag message format.
pub fn to_string(c: Config) -> String {
  let sync_line = case c.sync {
    True -> "sync = true"
    False -> "sync = false"
  }
  sync_line <> "\nsync.remote = " <> c.sync_remote <> "\n"
}
