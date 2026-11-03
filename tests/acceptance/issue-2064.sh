#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2064.sh
#
# Issue #2064: calibration-within.sh appends the share of results within the
# loop's horizon
#
# tools/calibration-within.sh reads the finished calibration table on stdin
# and appends a `within` column via table_append_column (#1650/#2060): for a
# row whose loop the horizon pack (ops packs/within.toml, flat
# `loop = <hours>`) names and whose fourth cell is a positive integer n, the
# cell is round(100 × numerator / n)% where the numerator counts proposals of
# that loop and class on ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl served by
# that row's model (the map of tools/tape-model.sh (#2059) at the proposal id,
# `-` when none), whose last outcome in tape order carries one of the loop's
# competence bits as true/1 and whose numbers.duration_s is a number at most
# the loop's hours × 3600. Stuck samples sit in n — the row's own counted
# denominator — and can never reach the numerator.
#
# Hermetic: fixture tape, table and packs in tmp dirs; TAPE_MODEL_TOOL is the
# real tools/tape-model.sh.
#
# Acceptance:
#   AC 1  dev/backlog grok-4.7 (p1 merged at 1200s, p2 merged at 7200s) ends
#         ` 50% |`; unsloth/Qwen3.8-27B (p3 merged at 3600s, p4 no outcome)
#         ends ` 50% |`; repair/pr-stale ends ` - |`; every other cell
#         byte-identical. A torn tape line is skipped, never fatal.
#   AC 2  a missing horizon pack appends the column, every row ` - |`, rc 0
#   AC 3  dev = "soon" (not a positive integer) exits 1 with empty stdout
#   AC 4  wiring: refresh_ops_calibration pipes the table through
#         calibration-within.sh after calibration-purpose.sh, and
#         gardener/AGENTS.md names the tool without disturbing the #1651,
#         #1652 and #2033 sentences
#   AC 5  bash -n tools/calibration-within.sh; the file is executable;
#         tests/acceptance/issue-1454.sh still passes
#
# Run via: tools/run-acceptance.sh 2064
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq python3
ac_assert_file "$REPO_ROOT/tools/calibration-within.sh" \
  "tools/calibration-within.sh is missing"
ac_assert_file "$REPO_ROOT/tools/tape-model.sh" \
  "tools/tape-model.sh (#2059) is missing"
ac_assert_file "$REPO_ROOT/gardener/gardener-run.sh" \
  "gardener/gardener-run.sh is missing"
ac_assert_file "$REPO_ROOT/gardener/AGENTS.md" \
  "gardener/AGENTS.md is missing"

WITHIN_TOOL="$REPO_ROOT/tools/calibration-within.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# dev's bits are `merged`; repair's are in the standard pack but repair has no
# horizon in AC 1, so its rows print `-`.
printf 'dev = "merged"\nrepair = "regression_cleared"\n' >"$WORK/loops.toml"
printf 'dev = 1\n' >"$WORK/within.toml"

# dev/backlog served by two models: grok's p1 merges inside 1h, p2 outside it;
# Qwen's p3 merges at exactly 1h (the boundary counts), p4 never merges. A
# torn final line must be skipped, not fatal.
mkdir -p "$WORK/tape"
printf '%s\n' \
  '{"type":"proposal","t":"2026-11-01T00:00:00Z","id":"p1","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2064-p1"}' \
  '{"type":"run","t":"2026-11-01T00:10:00Z","proposal_id":"p1","agent":"dsh/grok-4.7"}' \
  '{"type":"outcome","t":"2026-11-01T00:20:00Z","proposal_id":"p1","bits":{"merged":1},"numbers":{"duration_s":1200},"children":{},"payloads":[]}' \
  '{"type":"proposal","t":"2026-11-01T01:00:00Z","id":"p2","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2064-p2"}' \
  '{"type":"run","t":"2026-11-01T01:10:00Z","proposal_id":"p2","agent":"dsh/grok-4.7"}' \
  '{"type":"outcome","t":"2026-11-01T03:10:00Z","proposal_id":"p2","bits":{"merged":1},"numbers":{"duration_s":7200},"children":{},"payloads":[]}' \
  '{"type":"proposal","t":"2026-11-01T02:00:00Z","id":"p3","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2064-p3"}' \
  '{"type":"run","t":"2026-11-01T02:10:00Z","proposal_id":"p3","agent":"dsh/unsloth/Qwen3.8-27B"}' \
  '{"type":"outcome","t":"2026-11-01T03:10:00Z","proposal_id":"p3","bits":{"merged":1},"numbers":{"duration_s":3600},"children":{},"payloads":[]}' \
  '{"type":"proposal","t":"2026-11-01T04:00:00Z","id":"p4","loop":"dev","class":"backlog","context":{},"decision":"approved","ref":"2064-p4"}' \
  '{"type":"run","t":"2026-11-01T04:10:00Z","proposal_id":"p4","agent":"dsh/unsloth/Qwen3.8-27B"}' \
  '{torn' \
  >"$WORK/tape/tape.jsonl"

# The ten-column calibration table of #2062, one row per model; repair has no
# horizon in the pack.
TABLE='| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error |
|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | grok-4.7 | 2 | - | 100% | - | 4200.0 | - | - |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | 3600.0 | - | - |
| repair | pr-stale | - | 3 | - | 0% | - | - | - | - |'

# run_within <table> [horizon_pack]: fixture tape, loops pack and the real
# model tool are fixed; the horizon pack path is the caller's.
run_within() {
  local table="$1" pack="${2:-$WORK/within.toml}"
  RC=0
  OUT=""
  ERR=""
  TAPE_DIR="$WORK/tape" CALIBRATION_LOOPS_FILE="$WORK/loops.toml" \
    CALIBRATION_WITHIN_FILE="$pack" TAPE_MODEL_TOOL="$REPO_ROOT/tools/tape-model.sh" \
    bash "$WITHIN_TOOL" <<<"$table" >"$WORK/stdout.txt" 2>"$WORK/stderr.txt" || RC=$?
  OUT="$(cat "$WORK/stdout.txt" 2>/dev/null || true)"
  ERR="$(cat "$WORK/stderr.txt" 2>/dev/null || true)"
}

# ── AC 1: the share of each row's samples that came back inside the horizon ──
ac_log "AC 1: grok 1/2 inside 1h -> 50%, Qwen 1/2 (3600s boundary) -> 50%, repair - "
run_within "$TABLE"
ac_assert_eq "$RC" "0" "AC 1: a clean run must exit 0 (rc=$RC) [stderr: $ERR]"
if printf '%s\n' "$ERR" | grep -qF 'calibration-within:'; then
  ac_fail "AC 1: a clean run must not refuse (got: $ERR)"
fi
WANT='| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error | within |
|---|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | grok-4.7 | 2 | - | 100% | - | 4200.0 | - | - | 50% |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | 3600.0 | - | - | 50% |
| repair | pr-stale | - | 3 | - | 0% | - | - | - | - | - |'
ac_assert_eq "$OUT" "$WANT" "AC 1: appended table mismatch (got '$OUT')"
for row_suffix in '| 50% |' '| 50% |' '| - |'
do
  printf '%s\n' "$OUT" | grep -qF "$row_suffix" \
    || ac_fail "AC 1: a data row must end with '$row_suffix' (got: $OUT)"
done
ac_log "AC 1 OK: horizons counted per row, out-of-horizon loops print -, torn lines skipped"

# ── AC 2: a missing horizon pack appends the column with dashes ───────────────
ac_log "AC 2: no packs/within.toml -> every row prints -, rc 0"
run_within "$TABLE" "$WORK/no-such-pack.toml"
ac_assert_eq "$RC" "0" "AC 2: a missing horizon pack must not fail the tool (rc=$RC)"
WANT_DASH='| loop | class | model | n | promised | actual | error | mean duration_s | dur_promised | dur_error | within |
|---|---|---|---|---|---|---|---|---|---|---|
| dev | backlog | grok-4.7 | 2 | - | 100% | - | 4200.0 | - | - | - |
| dev | backlog | unsloth/Qwen3.8-27B | 2 | - | 50% | - | 3600.0 | - | - | - |
| repair | pr-stale | - | 3 | - | 0% | - | - | - | - | - |'
ac_assert_eq "$OUT" "$WANT_DASH" "AC 2: a missing pack must append the column with dashes (got '$OUT')"

# ── AC 3: an unparsable or non-positive horizon value is a hard failure ────────
ac_log "AC 3: dev = \"soon\" -> rc 1, empty stdout"
printf 'dev = "soon"\n' >"$WORK/within-soon.toml"
run_within "$TABLE" "$WORK/within-soon.toml"
ac_assert_eq "$RC" "1" "AC 3: a non-integer horizon must exit 1 (rc=$RC)"
ac_assert_eq "$OUT" "" "AC 3: a refusing run must write nothing (got '$OUT')"
printf '%s\n' "$ERR" | grep -qF 'calibration-within:' \
  || ac_fail "AC 3: stderr must name the failure with a calibration-within: line (got: $ERR)"
printf 'dev = 0\n' >"$WORK/within-zero.toml"
run_within "$TABLE" "$WORK/within-zero.toml"
ac_assert_eq "$RC" "1" "AC 3: a horizon of 0 hours must exit 1 (rc=$RC)"
ac_log "AC 3 OK: bad horizon values refuse with empty stdout"

# ── AC 4: gardener wiring and docs ─────────────────────────────────────────────
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
FN_SRC="$(ac_extract_fn refresh_ops_calibration "$GARDENER")"
[ -n "$FN_SRC" ] || ac_fail "AC 4: could not extract refresh_ops_calibration() from gardener-run.sh"
case "$FN_SRC" in
  *'calibration-purpose.sh" | "$FACTORY_ROOT/tools/calibration-within.sh"'*) ;;
  *) ac_fail "AC 4: the pipeline must pipe the table through calibration-within.sh after calibration-purpose.sh (got: $FN_SRC)" ;;
esac
ac_log "AC 4: wiring OK: within is the last stage of the refresh pipeline"

# shellcheck disable=SC2016  # backticks here are markdown, not command substitution
DOC_SENTENCE='Last through `tools/calibration-within.sh` (#2064), which appends a `within` column: the share of a row'"'"'s samples whose result came within the loop'"'"'s hours in the ops `packs/within.toml` (`-` for a loop the pack does not name).'
OWNER_SENTENCE='When a proposal carries grades by both, the owner'"'"'s (any `who` but `effect-scale`) is read over the code'"'"'s (#2033).'
FLAT_DOC="$(tr '\n' ' ' < "$REPO_ROOT/gardener/AGENTS.md" | tr -s ' ')"
printf '%s\n' "$FLAT_DOC" | grep -qF "$DOC_SENTENCE" \
  || ac_fail "AC 4: gardener/AGENTS.md must describe calibration-within.sh (#2064)"
printf '%s\n' "$FLAT_DOC" | grep -qF "$OWNER_SENTENCE $DOC_SENTENCE" \
  || ac_fail "AC 4: the #2064 sentence must come directly after the #2033 sentence"
ac_log "AC 4 OK: docs name the tool, right after the purpose sentence"

# The defaults must honor CALIBRATION_* env overrides, same shape as the
# stuck and graded packs.
grep -qF 'CALIBRATION_WITHIN_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/within.toml' \
  "$WITHIN_TOOL" \
  || ac_fail "AC 4: horizon pack default must be OPS_REPO_ROOT/packs/within.toml"
grep -qF 'TAPE_MODEL_TOOL:-$SCRIPT_DIR/tape-model.sh' "$WITHIN_TOOL" \
  || ac_fail "AC 4: model map default must be tools/tape-model.sh (#2059)"
ac_log "AC 4: defaults OK: packs/within.toml under OPS_REPO_ROOT, real tape-model.sh"

# ── AC 5: lint, executable bit, and the #1454 regression test ──────────────────
ac_log "AC 5: bash -n tools/calibration-within.sh"
bash -n "$WITHIN_TOOL" || ac_fail "AC 5: bash -n failed on tools/calibration-within.sh"
[ -x "$WITHIN_TOOL" ] || ac_fail "AC 5: tools/calibration-within.sh must be executable"

ac_log "AC 5: tests/acceptance/issue-1454.sh"
ac1454_rc=0
ac1454_out="$(bash "$REPO_ROOT/tests/acceptance/issue-1454.sh" 2>&1)" || ac1454_rc=$?
ac_assert_eq "$ac1454_rc" "0" \
  "AC 5: tests/acceptance/issue-1454.sh must pass (rc=$ac1454_rc): $ac1454_out"
ac_log "AC 5 OK: syntax, executable bit, and the #1454 refresh fixture pass"

ac_pass "issue #2064: calibration-within.sh appends the share of results within the loop's horizon"
