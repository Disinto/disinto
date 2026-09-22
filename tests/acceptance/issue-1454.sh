#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1454.sh
#
# Issue #1454: gardener writes catalog/calibration.md to the ops repo.
#
# After formula_session_end, bash only (no LLM), gardener-run.sh calls
# refresh_ops_calibration(), which runs tools/calibration.sh (#1453 table) and
# writes its stdout to ${OPS_REPO_ROOT}/catalog/calibration.md, then
# ops_commit_and_push("catalog: refresh calibration.md",
# catalog/calibration.md).
#
# Contract (per the issue):
#   - a failed calibration.sh only logs a warning and the gardener continues
#     (never dies); no stale/empty file is written
#   - a missing ops git (ops_commit_and_push no-op) still leaves the file on
#     disk
#   - formula_session_end precedes the new block
#
# Acceptance (read-only — no live services, no agents started; the extracted
# function is exercised in a throwaway subshell against a stub OPS_REPO_ROOT and
# a fixture TAPE_DIR, exactly as the issue asks):
#   1. wiring + order: in gardener-run.sh, formula_session_end precedes the
#      refresh_ops_calibration call, and the function invokes tools/calibration.sh
#      and ops_commit_and_push
#   2. a successful run (real tools/calibration.sh) writes
#      catalog/calibration.md whose first line is the calibration header, and
#      calls ops_commit_and_push with the refresh message + file
#   3. a failing calibration.sh (rc 3) → WARNING logged, rc 0 (gardener
#      continues), and no calibration.md written (no empty/stale file)
#
# Contract: executable bash, set -euo pipefail, exit 0, last stdout line PASS
# (or FAIL: <reason>). Uses tests/lib/acceptance-helpers.sh helpers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk jq

TARGET="$REPO_ROOT/gardener/gardener-run.sh"
ac_assert_file "$TARGET" "gardener/gardener-run.sh must exist"

# ── AC 1: wiring + ordering (formula_session_end before the refresh call) ──

ES=$(grep -n 'formula_session_end "\$GARDENER_RUN_RC"' "$TARGET" | head -n1 | cut -d: -f1)
RC=$(grep -n '^refresh_ops_calibration$' "$TARGET" | head -n1 | cut -d: -f1)
[ -n "$ES" ] || ac_fail "gardener-run.sh must call formula_session_end"
[ -n "$RC" ] || ac_fail "gardener-run.sh must call refresh_ops_calibration"
[ "$ES" -lt "$RC" ] \
  || ac_fail "formula_session_end (line $ES) must precede refresh_ops_calibration (line $RC)"
ac_log "AC 1 OK: formula_session_end (line $ES) precedes refresh_ops_calibration (line $RC)"

# ── Extract the function for in-process execution ──────────────────────────────

FN_SRC="$(ac_extract_fn refresh_ops_calibration "$TARGET")"
[ -n "$FN_SRC" ] || ac_fail "could not extract refresh_ops_calibration() from gardener-run.sh"
case "$FN_SRC" in
  *'"$FACTORY_ROOT/tools/calibration.sh"'*) ;;
  *) ac_fail "refresh_ops_calibration must invoke tools/calibration.sh" ;;
esac
case "$FN_SRC" in
  *"ops_commit_and_push"*) ;;
  *) ac_fail "refresh_ops_calibration must call ops_commit_and_push" ;;
esac
ac_log "AC 1 OK: refresh_ops_calibration() extracted and wires calibration.sh + ops_commit_and_push"

# ── Fixture builders ────────────────────────────────────────────────────────────

# A tape with one dev/fix pair (forecast 0.5, merged, dur 100) so the real
# calibration.sh prints a header + a data row.
write_tape() {
  local dir="$1"
  cat > "$dir/tape.jsonl" <<'TPE'
{"type":"proposal","t":"2026-02-01T00:00:00Z","id":"c-1","loop":"dev","class":"fix","context":{},"forecast":{"p_success":0.5,"est_cost":0,"est_dvision":0},"decision":"approved","ref":"1454-p1"}
{"type":"outcome","t":"2026-02-01T00:01:41Z","proposal_id":"c-1","bits":{"merged":1},"numbers":{"duration_s":100},"children":{},"payloads":[]}
TPE
}

# A stub factory whose tools/calibration.sh fails hard (rc 3).
write_failing_factory() {
  local factory="$1"
  mkdir -p "${factory}/tools"
  cat > "${factory}/tools/calibration.sh" <<'SH'
#!/usr/bin/env bash
# deliberately failing calibration stub for the rc!=0 path
echo "calibration: broken — jq unavailable in this test" >&2
exit 3
SH
  chmod +x "${factory}/tools/calibration.sh"
}

# ── Subshell runner: eval the extracted function with stub log/ops_commit_and_push ───
#
# Env: FACTORY_ROOT (real repo or failing stub), OPS_REPO_ROOT (writable stub
# dir — deliberately NOT a git repo, mirroring the "no ops git" no-op push),
# TAPE_DIR (fixture), PRIMARY_BRANCH. log() and ops_commit_and_push() are stubbed
# to emit lines the test asserts on.
run_refresh() {
  local factory="$1" ops_root="$2" tape_dir="$3"
  FACTORY_ROOT="$factory" OPS_REPO_ROOT="$ops_root" TAPE_DIR="$tape_dir" PRIMARY_BRANCH="main" \
    PICK_FN="$FN_SRC" bash -c '
    set -uo pipefail
    log() { printf "gardener: %s\n" "$*"; }
    ops_commit_and_push() {
      local msg="$1" f
      shift
      printf "OPS_PUSH msg=%s\n" "$msg"
      for f in "$@"; do
        printf "OPS_PUSH file=%s\n" "$f"
      done
    }
    eval "$PICK_FN"
    refresh_ops_calibration
  '
}

HEADER='| loop | class | n | promised | actual | error | mean duration_s |'
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── AC 2: successful run → catalog/calibration.md with header + commit call ─

OPS1="$TMP_DIR/ops-success"
mkdir -p "$OPS1"
TAPE1="$TMP_DIR/tape-success"
mkdir -p "$TAPE1"
write_tape "$TAPE1"

ac_log "AC 2: successful run → catalog/calibration.md + commit call"
rc=0
out="$(run_refresh "$REPO_ROOT" "$OPS1" "$TAPE1")" || rc=$?
ac_assert_eq "$rc" "0" "successful refresh must return 0 (got $rc): $out"
ac_assert_file "$OPS1/catalog/calibration.md" "catalog/calibration.md was not written to the ops repo"
FIRST="$(head -n 1 "$OPS1/catalog/calibration.md")"
ac_assert_eq "$FIRST" "$HEADER" \
  "calibration.md must start with the calibration header, got: $FIRST"
case "$out" in
  *"OPS_PUSH msg=catalog: refresh calibration.md"*) ;;
  *) ac_fail "must call ops_commit_and_push with the refresh message, got: $out" ;;
esac
case "$out" in
  *"OPS_PUSH file=catalog/calibration.md"*) ;;
  *) ac_fail "ops_commit_and_push must stage catalog/calibration.md, got: $out" ;;
esac
ac_log "AC 2 OK: calibration.md written with header; ops_commit_and_push called (no-op push, file on disk)"

# ── AC 3: failing calibration.sh → WARNING, rc 0, no file written ────────────

OPS2="$TMP_DIR/ops-fail"
mkdir -p "$OPS2"
FACTORY_FAIL="$TMP_DIR/factory-fail"
write_failing_factory "$FACTORY_FAIL"
TAPE2="$TMP_DIR/tape-fail"
mkdir -p "$TAPE2"
write_tape "$TAPE2"

ac_log "AC 3: failing calibration.sh → WARNING, rc 0, no file written"
rc=0
out="$(run_refresh "$FACTORY_FAIL" "$OPS2" "$TAPE2")" || rc=$?
ac_assert_eq "$rc" "0" "a failing calibration.sh must not abort the gardener (rc=$rc): $out"
case "$out" in
  *"WARNING"*) ;;
  *) ac_fail "a failing calibration.sh must log a WARNING, got: $out" ;;
esac
case "$out" in
  *"calibration.sh failed"*) ;;
  *) ac_fail "the WARNING must name calibration.sh, got: $out" ;;
esac
[ ! -f "$OPS2/catalog/calibration.md" ] \
  || ac_fail "a failed refresh must not leave a (stale/empty) calibration.md behind"
ac_log "AC 3 OK: failing calibration.sh warns and the gardener continues"

ac_pass
