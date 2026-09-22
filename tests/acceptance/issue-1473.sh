#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1473.sh
#
# Issue #1473: calibration counts only a loop's own competence bit.
#
# Before: the table scored every (loop, class) group on bits.merged, so repair
# and review pairs always showed 0% (no merged bit) and dev rows mixed dev PR
# outcomes with formula-session end outcomes (bits.exit_ok). Now a pair counts
# in n, promised, actual, and mean duration_s only when its LAST outcome carries
# the loop's own competence bit (true/false/1/0):
#
#   dev    -> bits.merged
#   repair -> bits.regression_cleared
#
#   true/1 is a success, false/0 a failure. Any other loop, or a last outcome
# without the bit, is dropped (never counted as 0%; no row for a group whose
# every pair is dropped, header row only).
#
# Acceptance (read-only — no live services, no agents started, no state
# mutation; hand-written tmp fixture tapes exercise the tool, exactly as the
# issue asks):
#   1. 10 dev merged:1 + 6 dev exit_ok:1 -> n=10, actual=100% (the 6 formula
#      sessions are not counted; mean is over the 10 samples only)
#   2. repair regression_cleared:1 (plus a repair sibling that carries only
#      merged) -> n=1, actual=100%; missing bit is never 0%
#   3. repair regression_cleared:0 -> counts in n as a failure: n=1, actual=0%
#   4. tape where every pair is non-sample (exit_ok-only, merged-only repair,
#      review) -> header row only, rc 0
#   5. empty tape -> header row only, rc 0
#   6. `bats tests/calibration.bats` passes (the bats suite is the regression
#      net for the full table + edge cases)
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq awk grep bats

TOOL="$REPO_ROOT/tools/calibration.sh"

# ── Shared table constants ────────────────────────────────────────────────────
# Exact output of the tool's header + separator row (no leading space).
HEADER=$'| loop | class | n | promised | actual | error | mean duration_s |\n|---|---|---|---|---|---|---|'

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Fixture builders ──────────────────────────────────────────────────────────

# AC 1 tape: 10 dev/fix pairs whose last outcome is merged:1 (dur 100) and 6
# dev/fix pairs whose last outcome is exit_ok:1 only (dur 999).
write_ac1_tape() {
  {
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf '{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"d-%s","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1473-d%s"}\n' "$i" "$i"
      printf '{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"d-%s","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}\n' "$i"
    done
    for i in 1 2 3 4 5 6; do
      printf '{"type":"proposal","t":"2026-02-01T00:02:00Z","id":"f-%s","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1473-f%s"}\n' "$i" "$i"
      printf '{"type":"outcome","t":"2026-02-01T00:02:01Z","proposal_id":"f-%s","bits":{"exit_ok":1},"numbers":{"duration_s":999},"children":{},"payloads":[]}\n' "$i"
    done
  } > "$1/tape.jsonl"
}

# AC 2 tape: two repair/incident pairs.
#   r-1 last outcome regression_cleared:1, dur 100  -> the only sample
#   r-2 last outcome merged:1, dur 200              -> non-sample, dropped
write_ac2_tape() {
  cat > "$1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1473-r1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"regression_cleared":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
{"type":"proposal","t":"2026-02-01T00:03:00Z","id":"r-2","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1473-r2"}
{"type":"outcome","t":"2026-02-01T00:04:00Z","proposal_id":"r-2","bits":{"merged":1},"numbers":{"duration_s":200},"children":{},"payloads":[]}
EOF
}

# AC 3 tape: one repair/incident pair whose last outcome is regression_cleared:0
# (no duration).
write_ac3_tape() {
  cat > "$1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1473-r1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"r-1","bits":{"regression_cleared":0},"children":{},"payloads":[]}
EOF
}

# AC 4 tape: three pairs, none carrying its loop's competence bit in the last
# outcome -> the whole tape is non-sample (header row only).
write_ac4_tape() {
  cat > "$1/tape.jsonl" <<'EOF'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"f-1","loop":"dev","class":"fix","context":{},"decision":"approved","ref":"1473-f1"}
{"type":"outcome","t":"2026-02-01T00:01:00Z","proposal_id":"f-1","bits":{"exit_ok":1}}
{"type":"proposal","t":"2026-02-01T00:02:00Z","id":"r-1","loop":"repair","class":"incident","context":{},"decision":"approved","ref":"1473-r1"}
{"type":"outcome","t":"2026-02-01T00:03:00Z","proposal_id":"r-1","bits":{"merged":1}}
{"type":"proposal","t":"2026-02-01T00:04:00Z","id":"v-1","loop":"review","class":"docs","context":{},"decision":"approved","ref":"1473-v1"}
{"type":"outcome","t":"2026-02-01T00:05:00Z","proposal_id":"v-1","bits":{"merged":1}}
EOF
}

# ── AC 1: 10 merged + 6 exit_ok-only dev outcomes -> n=10 actual=100% ────────

ac_log "AC 1: 10 dev merged + 6 exit_ok-only outcomes -> n=10, actual=100%"
TC_DIR="$TMP_DIR/tape-ac1"
mkdir -p "$TC_DIR"
write_ac1_tape "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "dev AC 1 fixture must exit 0 (rc=$rc)"

# The 6 formula-session pairs carry no merged bit -> dropped: the single row
# covers the 10 dev PR pairs only; mean duration is over those 10 (100s),
# never diluted by the 999-s exit_ok durations.
expected="$HEADER
| dev | fix | 10 | - | 100% | - | 100.0 |"
ac_assert_eq "$out" "$expected" \
  "AC 1 must print n=10 actual=100% mean=100.0 for the merged dev pairs only, got: $out"

ac_log "AC 1 OK: exit_ok-only outcomes are not samples"

# ── AC 2: regression_cleared decides for repair (never 0% for missing merged) ──

ac_log "AC 2: repair regression_cleared:1 -> 100% (missing merged is not 0%)"
TC_DIR="$TMP_DIR/tape-ac2"
mkdir -p "$TC_DIR"
write_ac2_tape "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "repair AC 2 fixture must exit 0 (rc=$rc)"

# Only r-1 carries regression_cleared -> n=1 (not 2), 100%, mean 100.0
# (not 50% / 150.0).
expected="$HEADER
| repair | incident | 1 | - | 100% | - | 100.0 |"
ac_assert_eq "$out" "$expected" \
  "AC 2 must count only the regression_cleared pair (n=1, 100%, mean 100.0), got: $out"

ac_log "AC 2 OK: repair counts regression_cleared, never 0% for a missing bit"

# ── AC 3: regression_cleared:0 counts in n as a failure ──────────────────────

ac_log "AC 3: repair regression_cleared:0 -> failure counted in n"
TC_DIR="$TMP_DIR/tape-ac3"
mkdir -p "$TC_DIR"
write_ac3_tape "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "repair AC 3 fixture must exit 0 (rc=$rc)"

# Bit present (0) -> a sample with a failure: n=1, actual=0%. No duration
# -> mean "-".
expected="$HEADER
| repair | incident | 1 | - | 0% | - | - |"
ac_assert_eq "$out" "$expected" \
  "AC 3 must count the regression_cleared:0 pair as a failure (n=1, 0%), got: $out"

ac_log "AC 3 OK: regression_cleared:0 is a failure, not a drop"

# ── AC 4: all-non-sample tape -> header row only, rc 0 ───────────────────────

ac_log "AC 4: all-non-sample tape -> header row only, rc 0"
TC_DIR="$TMP_DIR/tape-ac4"
mkdir -p "$TC_DIR"
write_ac4_tape "$TC_DIR"

rc=0
out="$(TAPE_DIR="$TC_DIR" bash "$TOOL")" || rc=$?
ac_assert_eq "$rc" "0" "all-non-sample fixture must exit 0 (rc=$rc)"
ac_assert_eq "$out" "$HEADER" \
  "AC 4 must print the header row only (no 0% row for missing bits), got: $out"

ac_log "AC 4 OK: non-sample groups print no row"

# ── AC 5: empty tape -> header row only, rc 0 ─────────────────────────────────

ac_log "AC 5: empty tape -> header row only, rc 0"
EMPTY_DIR="$TMP_DIR/tape-0"
ac_run_empty_tape "$EMPTY_DIR" "$TOOL"
ac_assert_eq "$rc" "0" "empty tape must exit 0 (rc=$rc)"
ac_assert_eq "$out" "$HEADER" \
  "AC 5: empty tape must print the header row only, got: $out"

ac_log "AC 5 OK: empty tape -> header only, rc 0"

# ── AC 6: `bats tests/calibration.bats` passes ───────────────────────────────

ac_log "AC 6: bats tests/calibration.bats passes"
# The bats suite is the regression net for the full table (multi-group rows,
# last-outcome pairing, dropped-pair semantics, sorting, malformed-line skip,
# read-only behavior). bats exits 0 when every test passes.
bats_rc=0
bats_out="$(bats "$REPO_ROOT/tests/calibration.bats" 2>&1)" || bats_rc=$?
ac_assert_eq "$bats_rc" "0" "bats tests/calibration.bats must pass (rc=$bats_rc): $bats_out"

ac_log "AC 6 OK: bats suite green"

ac_pass
