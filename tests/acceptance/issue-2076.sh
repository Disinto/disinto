#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2076.sh
#
# Issue #2076: a stop rule that cannot evaluate never lifts a suspension.
#
#   repair_direct_dispatch asks repair_suspended before running a direct
#   recipe. repair_suspended prints "<failed> <counted>" when the rule
#   evaluated; when the pack or the tape is unreadable it prints nothing and
#   returns 1. The old `*)` arm treated every other rc as a lift — deleting
#   the "told once" marker, logging "suspension lifted", drafting the lifted
#   claim and running the script. This test drives the extracted dispatch
#   with stubs:
#
#   1. repair_suspended prints nothing, returns 1, and
#      $TAPE_DIR/repair/boom.suspended exists: the marker is unchanged, the
#      script does not run, repair_claim_pr is not called, and the log holds
#      "stop rule unreadable: boom stays suspended".
#   2. repair_suspended prints nothing, returns 1, no marker: the script runs
#      once and no "suspension lifted" line is logged.
#   3. repair_suspended prints "3 20", returns 1, marker present: the marker
#      is removed, "suspension lifted: boom" is logged, repair_claim_pr is
#      called with "lifted", and the script runs.
#   4. supervisor/supervisor-run.sh parses, and issue-2054.sh (the lift path
#      that prints counts) still passes.
#
# Hermetic: no network, no live services. A temp TAPE_DIR, stub functions and
# a stub action script.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash awk grep mktemp date

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DISPATCH_SRC="$(ac_extract_fn repair_direct_dispatch "$TARGET")"
[ -n "$DISPATCH_SRC" ] || ac_fail "could not extract repair_direct_dispatch() from supervisor-run.sh"
CLEAR_SRC="$(ac_extract_fn repair_suspension_clear "$TARGET")"
[ -n "$CLEAR_SRC" ] || ac_fail "could not extract repair_suspension_clear() from supervisor-run.sh"

# ── wiring: the unreadable-rule arm checks the marker, not a blind lift ──────
ac_log "AC 0: repair_direct_dispatch distinguishes an evaluated lift from an unreadable rule"
printf '%s\n' "$DISPATCH_SRC" | grep -qE 'stop rule unreadable: .* stays suspended' \
  || ac_fail "repair_direct_dispatch must log 'stop rule unreadable' for an unevaluable rule with a marker"
printf '%s\n' "$DISPATCH_SRC" | grep -qE '\.suspended" \]; then' \
  || ac_fail "repair_direct_dispatch must test the suspension marker before running the script"

# ── fixtures: one fired recipe named boom, one stub script ────────────────────
mkdir -p "$TMP_DIR/factory/supervisor/actions"
cat > "$TMP_DIR/factory/supervisor/actions/boom.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "$SCRIPT_MARKER"
EOF
chmod +x "$TMP_DIR/factory/supervisor/actions/boom.sh"

RECIPE='{"fired":[{"name":"boom","action":"direct","action_script":"supervisor/actions/boom.sh","evidence":"disk pressure"}]}'
MARK="$TMP_DIR/tape/repair/boom.suspended"
MARK_CONTENT="1760000000 10 12"

# run_dispatch <what-repair_suspended-prints> <its-rc> <marker-content-or-empty>
# One dispatch tick in an isolated subshell: the extracted dispatch plus the
# real marker helper, every mutating call stubbed. The tick's combined log
# lands in OUT, its exit status in RC, script runs are counted in
# $TMP_DIR/script-ran, and repair_claim_pr calls in $TMP_DIR/claims.
run_dispatch() {
  local printed="$1" rc="$2" marker="$3"
  rm -f "$TMP_DIR/script-ran" "$TMP_DIR/claims"
  mkdir -p "$TMP_DIR/tape/repair"
  rm -f "$MARK"
  if [ -n "$marker" ]; then
    printf '%s\n' "$marker" > "$MARK"
  fi
  RC=0
  OUT=""
  # shellcheck disable=SC2317  # stubs defined inside the subshell are the point
  OUT="$(
    set -euo pipefail
    STUB_PRINTED="$printed"
    STUB_RC="$rc"
    export STUB_PRINTED STUB_RC TAPE_DIR="$TMP_DIR/tape"
    export FACTORY_ROOT="$TMP_DIR/factory"
    export PROJECT_TOML="$FACTORY_ROOT/projects/disinto.toml"
    export SCRIPT_MARKER="$TMP_DIR/script-ran"
    log() { printf '%s\n' "$*"; }
    repair_suspended() {
      if [ -n "$STUB_PRINTED" ]; then
        printf '%s\n' "$STUB_PRINTED"
      fi
      return "$STUB_RC"
    }
    repair_claim_pr() {
      printf 'claim %s %s\n' "${3:-}" "${4:-}" >> "$TMP_DIR/claims"
      return 0
    }
    notice_owner() { printf 'notice %s\n' "${1:-}" >> "$TMP_DIR/claims"; return 0; }
    tape_run() { return 0; }
    emit_repair_proposal() { return 0; }
    repair_tape_state_file() { printf '%s\n' "$TMP_DIR/no-such-state.json"; }
    eval "$CLEAR_SRC"
    eval "$DISPATCH_SRC"
    repair_direct_dispatch "$RECIPE"
  )" || RC=$?
  ac_assert_eq "$RC" "0" "the tick must still return 0 (got $RC): $OUT"
}

# How many times the stub script ran in the last tick (0 when the sentinel
# file was never created).
runs() {
  if [ -f "$TMP_DIR/script-ran" ]; then
    wc -l < "$TMP_DIR/script-ran" | tr -d ' '
  else
    printf '0\n'
  fi
}

# ── AC 1: unreadable rule + marker: fails closed, marker kept, script skipped ─
ac_log "AC 1: repair_suspended prints nothing and returns 1 with a marker — stays suspended"
run_dispatch "" 1 "$MARK_CONTENT"
[ -f "$MARK" ] || ac_fail "an unevaluable rule must not remove the suspension marker, got: $OUT"
ac_assert_eq "$(cat "$MARK")" "$MARK_CONTENT" "the marker must be unchanged (got: $(cat "$MARK"))"
ac_assert_eq "$(runs)" "0" "a recipe that stays suspended must not run its script"
if [ -e "$TMP_DIR/claims" ]; then
  ac_fail "an unevaluable rule must not draft a lifted claim, got: $(cat "$TMP_DIR/claims")"
fi
case "$OUT" in
  *"stop rule unreadable: boom stays suspended"* ) ;;
  *) ac_fail "expected 'stop rule unreadable: boom stays suspended', got: $OUT" ;;
esac
case "$OUT" in
  *"suspension lifted"* ) ac_fail "an unevaluable rule must not log a lift, got: $OUT" ;;
esac

# ── AC 2: unreadable rule, no marker: the rule is off, run as before ──────────
ac_log "AC 2: no marker and nothing printed — the script runs, no lift is logged"
run_dispatch "" 1 ""
ac_assert_eq "$(runs)" "1" "with no marker the recipe runs exactly once (got $(runs) runs)"
[ ! -e "$MARK" ] || ac_fail "the unreadable rule must not create a marker"
if [ -e "$TMP_DIR/claims" ]; then
  ac_fail "an off rule with no marker drafts nothing, got: $(cat "$TMP_DIR/claims")"
fi
case "$OUT" in
  *"suspension lifted"* ) ac_fail "a rule that never suspended must not log a lift, got: $OUT" ;;
esac
case "$OUT" in
  *"stop rule unreadable"* ) ac_fail "a recipe without a marker needs no unreadable-rule log line, got: $OUT" ;;
esac

# ── AC 3: evaluated, not suspended + marker: the real lift ────────────────────
ac_log "AC 3: repair_suspended prints '3 20' and returns 1 with a marker — the lift clears it"
run_dispatch "3 20" 1 "$MARK_CONTENT"
[ ! -e "$MARK" ] || ac_fail "an evaluated, not-suspended result must remove the marker, got: $OUT"
case "$OUT" in
  *"suspension lifted: boom"* ) ;;
  *) ac_fail "expected 'suspension lifted: boom', got: $OUT" ;;
esac
ac_assert_eq "$(cat "$TMP_DIR/claims" 2>/dev/null)" "claim lifted 3 20" \
  "the lift must draft the claim revision with the evaluated counts"
ac_assert_eq "$(runs)" "1" "a lifted recipe runs its script (got $(runs) runs)"

# ── AC 4: syntax, and the lift-path test still passes ─────────────────────────
ac_log "AC 4: supervisor-run.sh parses and issue-2054.sh still passes"
bash -n "$TARGET" || ac_fail "bash -n failed on supervisor/supervisor-run.sh"
SIBLING="$REPO_ROOT/tests/acceptance/issue-2054.sh"
ac_assert_file "$SIBLING" "tests/acceptance/issue-2054.sh must exist"
rc=0
sibling_out="$(bash "$SIBLING" 2>&1)" || rc=$?
ac_assert_eq "$rc" "0" "issue-2054.sh must still pass (got $rc): $sibling_out"
case "$sibling_out" in
  *PASS* ) ;;
  *) ac_fail "issue-2054.sh printed no PASS: $sibling_out" ;;
esac

ac_pass
