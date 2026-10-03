#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1648.sh
#
# Issue #1648: feat(tools): list stuck proposals as calibration samples
#
# Calibration (#1393) drops every proposal that never got an outcome carrying
# its loop's competence bit, so nothing coming back reads as nothing. The
# design: a proposal with no competence outcome after its loop's horizon counts
# as one failure sample, read at read time; no record is written.
# tools/tape-stuck.sh is that reader. A proposal is stuck when its loop is a
# key of both the loops pack (as tools/calibration.sh parses it) and the
# stuck pack (flat `loop = <hours>` TOML at $CALIBRATION_STUCK_FILE), its
# decision is not `rejected`, its `t` is more than the loop's hours before
# $CALIBRATION_NOW (ISO-8601 UTC, fixed here), and its last outcome in tape
# order carries none of the loop's bits (true/false/1/0) — or it has no
# outcome at all.
#
# The output is one JSON array, one object per stuck proposal, in the sample
# shape calibration groups on:
#   {"loop","class","promised","est_dvision","competence","duration","signature"}
# promised = forecast.p_success when numeric else null; est_dvision and
# duration always null; competence [false]; signature "stuck" (#1651).
#
# Hermetic: no network, no forge, no agents, no writes. Per-scenario tmp
# TAPE_DIRs, fixture packs, fixed CALIBRATION_NOW.
#
# Acceptance:
#   AC1  stuck pack `dev = 48`, clock 72 h after a dev proposal with no
#        outcome -> one object, loop "dev", competence [false]
#   AC2  the same proposal 24 h old -> []
#   AC3  last outcome {merged: 0} -> not listed (already a failure sample);
#        last outcome only {exit_ok: 1} -> listed
#   AC4  without LOOPS_JSON and with a fixture loops pack `dev = "merged"`
#        -> the same output as with `{"dev":["merged"]}`
#   AC5  decision "rejected" -> not listed; missing stuck pack -> [];
#        `dev = "soon"` -> exit 1
#   AC6  missing tape -> [] (rc 0)
#   AC7  malformed lines are skipped, never fatal
#
# Run via: tools/run-acceptance.sh 1648
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
ac_assert_file "$REPO_ROOT/tools/tape-stuck.sh" "tools/tape-stuck.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture packs (hermetic, no ops repo involved) ────────────────────────────

PACKS="$TMP_DIR/packs"
mkdir -p "$PACKS"
cat > "$PACKS/loops.toml" <<'EOF'
dev = ["merged", "rejected"]
sprint = ["effect"]
EOF
# The single-string form of the same dev entry (pre-#1614 shape): read as a
# one-element array.
cat > "$PACKS/loops-string.toml" <<'EOF'
dev = "merged"
EOF
cat > "$PACKS/stuck.toml" <<'EOF'
dev = 48
EOF
cat > "$PACKS/stuck-bad.toml" <<'EOF'
dev = "soon"
EOF

# Fixed clock: 2026-02-10 00:00:00 UTC. 72 h old = 2026-02-07T00:00:00Z;
# 24 h old = 2026-02-09T00:00:00Z.
export CALIBRATION_NOW="2026-02-10T00:00:00Z"
export CALIBRATION_LOOPS_FILE="$PACKS/loops.toml"
export CALIBRATION_STUCK_FILE="$PACKS/stuck.toml"
export TAPE_DIR="$TMP_DIR/tape"
mkdir -p "$TAPE_DIR"

# run_stuck [tool-args...] — run the tool; the result lands in $OUT (stdout),
# $ERR (stderr), $RC. The tool's stdout is never leaked onto the test's
# stdout, so the last line there stays PASS.
run_stuck() {
  RC=0
  OUT=""
  OUT="$(bash "$REPO_ROOT/tools/tape-stuck.sh" "$@" 2>"$TMP_DIR/err")" || RC=$?
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# ── AC1: 72 h old, no outcome, dev = 48 -> one failure sample ───────────────

ac_log "AC1: 72 h old dev proposal with no outcome -> stuck"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-1","loop":"dev","class":"backlog","context":{},"forecast":{"p_success":0.7,"est_cost":0,"est_dvision":3600},"decision":"approved","ref":"1648-1"}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC1: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 1' "$OUT" "AC1: exactly one stuck proposal, got: $OUT"
ac_assert_jq '.[0].loop == "dev" and .[0].class == "backlog"' "$OUT" \
  "AC1: sample carries the proposal's loop and class"
ac_assert_jq '.[0].competence == [false]' "$OUT" "AC1: a stuck proposal is a failure sample"
ac_assert_jq '.[0].signature == "stuck"' "$OUT" "AC1: signature is stuck (#1651)"
ac_assert_jq '.[0].promised == 0.7 and .[0].est_dvision == null and .[0].duration == null' \
  "$OUT" "AC1: promised from forecast, est_dvision and duration null"
ac_log "AC1 OK"

# ── AC2: the same proposal 24 h old -> [] ────────────────────────────────────

ac_log "AC2: 24 h old (inside the 48 h horizon) -> not stuck"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-09T00:00:00Z","id":"p-2","loop":"dev","class":"backlog","context":{},"forecast":{"p_success":0.7,"est_cost":0,"est_dvision":3600},"decision":"approved","ref":"1648-2"}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC2: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "[]" "AC2: a proposal inside the horizon is not stuck (got: $OUT)"
ac_log "AC2 OK"

# ── AC3: last outcome's bits decide ──────────────────────────────────────────

ac_log "AC3a: last outcome {merged: 0} -> not listed (already a failure sample)"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-3","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1648-3"}
{"type":"outcome","t":"2026-02-09T00:00:00Z","proposal_id":"p-3","bits":{"merged":0},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC3a: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "[]" "AC3a: a last outcome carrying a loop bit is a sample already (got: $OUT)"

ac_log "AC3b: last outcome only {exit_ok: 1} -> listed"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-4","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1648-4"}
{"type":"outcome","t":"2026-02-09T00:00:00Z","proposal_id":"p-4","bits":{"exit_ok":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC3b: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 1 and .[0].loop == "dev" and .[0].competence == [false]' \
  "$OUT" "AC3b: an outcome with no loop bit leaves the proposal stuck (got: $OUT)"
ac_log "AC3 OK"

# ── AC4: string loops pack == one-element array ──────────────────────────────

ac_log "AC4: dev = \"merged\" pack == {\"dev\":[\"merged\"]} arg"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-5","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1648-5"}
EOF
run_stuck '{"dev":["merged"]}'
OUT_ARRAY="$OUT"
CALIBRATION_LOOPS_FILE="$PACKS/loops-string.toml" run_stuck
ac_assert_eq "$OUT" "$OUT_ARRAY" \
  "AC4: the string pack must emit the same output as {\"dev\":[\"merged\"]} (pack: $OUT, arg: $OUT_ARRAY)"
ac_assert_jq 'length == 1 and .[0].competence == [false]' "$OUT_ARRAY" \
  "AC4: the shared output lists p-5 stuck"
ac_log "AC4 OK"

# ── AC5: rejected / missing stuck pack / non-integer hours ───────────────────

ac_log "AC5a: decision \"rejected\" -> not listed"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-6","loop":"dev","class":"backlog","context":{},"decision":"rejected","ref":"1648-6"}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC5a: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "[]" "AC5a: rejected proposals are not stuck samples (got: $OUT)"

ac_log "AC5b: missing stuck pack -> []"
CALIBRATION_STUCK_FILE="$TMP_DIR/none.toml" run_stuck
ac_assert_eq "$RC" "0" "AC5b: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "[]" "AC5b: a missing stuck pack prints [] (got: $OUT)"

ac_log 'AC5c: stuck pack with dev = "soon" -> exit 1'
CALIBRATION_STUCK_FILE="$PACKS/stuck-bad.toml" run_stuck
ac_assert_eq "$RC" "1" "AC5c: a non-integer stuck pack value must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC5c: must print nothing on stdout (got: $OUT)"
ac_log "AC5 OK"

# ── AC6: missing tape -> [] ──────────────────────────────────────────────────

ac_log "AC6: missing tape -> []"
export TAPE_DIR="$TMP_DIR/tape-none"
mkdir -p "$TMP_DIR/tape-none"
run_stuck
ac_assert_eq "$RC" "0" "AC6: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_eq "$OUT" "[]" "AC6: a missing tape prints [] (got: $OUT)"
export TAPE_DIR="$TMP_DIR/tape"
ac_log "AC6 OK"

# ── AC7: malformed lines are skipped, never fatal ────────────────────────────

ac_log "AC7: malformed lines are skipped with a stderr note"
cat > "$TAPE_DIR/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-07T00:00:00Z","id":"p-7","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"1648-7"}
NOT A JSON LINE
{"type":"proposal","t":"2026-02-06T00:00:00Z","id":"p-8","loop":"sprint","class":"experiment","context":{},"decision":"approved","ref":"1648-8"}
EOF
run_stuck
ac_assert_eq "$RC" "0" "AC7: must exit 0 (rc=$RC, err: $ERR)"
ac_assert_jq 'length == 1' "$OUT" "AC7: valid proposals are still listed (got: $OUT)"
ac_assert_eq "$ERR" \
  "tape-stuck: skipped 1 malformed line(s) in $TMP_DIR/tape/tape.jsonl" \
  "AC7: malformed lines are reported on stderr (got: $ERR)"
ac_log "AC7 OK"

ac_pass