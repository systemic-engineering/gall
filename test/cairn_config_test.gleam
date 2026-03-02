import cairn/config
import gleeunit/should

// ---------------------------------------------------------------------------
// default_test
//
// Defaults: sync off, remote = garden@systemic.engineering
// ---------------------------------------------------------------------------

pub fn default_test() {
  let c = config.default()
  c.sync |> should.equal(False)
  c.sync_remote |> should.equal("garden@systemic.engineering")
}

// ---------------------------------------------------------------------------
// parse_empty_test
//
// Empty tag content → defaults
// ---------------------------------------------------------------------------

pub fn parse_empty_test() {
  let c = config.parse("")
  c.sync |> should.equal(False)
  c.sync_remote |> should.equal("garden@systemic.engineering")
}

// ---------------------------------------------------------------------------
// parse_sync_true_test
// ---------------------------------------------------------------------------

pub fn parse_sync_true_test() {
  let c = config.parse("sync = true\n")
  c.sync |> should.equal(True)
  c.sync_remote |> should.equal("garden@systemic.engineering")
}

// ---------------------------------------------------------------------------
// parse_sync_remote_test
// ---------------------------------------------------------------------------

pub fn parse_sync_remote_test() {
  let c = config.parse("sync = true\nsync.remote = patches@example.org\n")
  c.sync |> should.equal(True)
  c.sync_remote |> should.equal("patches@example.org")
}

// ---------------------------------------------------------------------------
// to_string_round_trip_test
// ---------------------------------------------------------------------------

pub fn to_string_round_trip_test() {
  let c = config.Config(sync: True, sync_remote: "patches@example.org")
  let s = config.to_string(c)
  let c2 = config.parse(s)
  c2.sync |> should.equal(True)
  c2.sync_remote |> should.equal("patches@example.org")
}
