#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1681.sh
#
# Issue #1681: the supervisor runs without LLM escalation unless it is
# switched on.
#
# Problem: the supervisor handed any fired recipe that is not a direct
# remedy to an LLM session (agent_run, Claude Opus via CLAUDE_MODEL =
# "claude-opus-4-6" in nomad/jobs/agents-supervisor-opus.hcl). This
# deployment runs no Anthropic models, so the supervisor job was stopped
# on 2026-10-02 — and with it its bash health checks, direct remedies and
# repair records. The supervisor should be able to run bash-only.
#
# Fix: a new escalation_off RECIPE_OUTPUT function in
# supervisor/supervisor-run.sh. When SUPERVISOR_LLM_ESCALATION is "on" it
# returns 1 (do nothing — keep the LLM escalation); otherwise it logs one
# line, `LLM escalation off: <n> fired recipe(s) left for a human: <names>`,
# naming the fired recipes whose `action` is not `direct` or whose
# `action_script` is `__MISSING__`, and returns 0 so the gate falls to the
# bash fast path (direct remedies, journal, incident files, exit 0).
# The HCL job sets SUPERVISOR_LLM_ESCALATION = "off" and drops CLAUDE_MODEL.
#
# Self-contained: no network. escalation_off is extracted from
# supervisor/supervisor-run.sh with ac_extract_fn() + eval, log() is stubbed,
# and a fixture recipe JSON is fed in.
#
# Acceptance criteria exercised here:
#   1. escalation_off with a fixture holding one `incident` fire (pr-stale)
#      and the variable unset -> returns 0 and logs a line naming pr-stale.
#   2. The same with SUPERVISOR_LLM_ESCALATION=on -> returns 1 and logs
#      nothing.
#   3. A fire with action: direct and a real action_script is not named.
#   4. (run-level, enforced by tools/run-acceptance.sh) bash
#      tests/acceptance/issue-1681.sh exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# The extracted function calls log(); a top-level stand-in (inherited by the
# run subshells) that prints a prefixed line to stdout so the test can
# inspect exactly what the function logged.
log() { printf 'LOG: %s\n' "$*"; }

# ── Wiring: the function exists in the top-level supervisor executable ──────
ESCALATION_SRC="$(ac_extract_fn escalation_off "$TARGET")"
[ -n "$ESCALATION_SRC" ] || ac_fail "could not extract escalation_off() from supervisor-run.sh"

# The wiring: escalation_off must be called from the LLM escalation gate
# right before the `if [ "$LLM_REQUIRED" = false ]` check, with
# LLM_REQUIRED=true as its guard.
grep -qF 'if [ "$LLM_REQUIRED" = true ] && escalation_off' "$TARGET" \
  || ac_fail "supervisor-run.sh must call escalation_off from the LLM escalation gate"
grep -qF 'escalation_off "$RECIPE_OUTPUT"' "$TARGET" \
  || ac_fail "escalation_off must be called with RECIPE_OUTPUT"
# The escalation check must sit before the fast-path check (otherwise the
# demotion would be unreachable when the gate already says LLM is needed).
GATE_LINE="$(grep -n '^if \[ "$LLM_REQUIRED" = true \] && escalation_off' "$TARGET" | head -n1 | cut -d: -f1 || true)"
FAST_PATH_LINE="$(grep -n '^if \[ "$LLM_REQUIRED" = false \]; then$' "$TARGET" | head -n1 | cut -d: -f1 || true)"
[ -n "$GATE_LINE" ] && [ -n "$FAST_PATH_LINE" ] \
  || ac_fail "escalation_off call / fast-path check missing or not top-level"
[ "$GATE_LINE" -lt "$FAST_PATH_LINE" ] \
  || ac_fail "escalation_off gate must run before the fast-path check (line $GATE_LINE > $FAST_PATH_LINE)"

# ── HCL job: bash-only by default ──────────────────────────────────────────
HCL="$REPO_ROOT/nomad/jobs/agents-supervisor-opus.hcl"
ac_assert_file "$HCL" "nomad/jobs/agents-supervisor-opus.hcl must exist"
# No Anthropic model pin anywhere in the job (it runs no Claude). grep -c
# exits 1 when the count is zero, so capture it rather than let set -e
# abort.
CLAUDE_COUNT="$(grep -c CLAUDE_MODEL "$HCL" || true)"
ac_assert_eq "$CLAUDE_COUNT" "0" "supervisor job must not pin CLAUDE_MODEL"
grep -qF 'SUPERVISOR_LLM_ESCALATION = "off"' "$HCL" \
  || ac_fail "supervisor job must set SUPERVISOR_LLM_ESCALATION = \"off\""

# ── Fixture: one incident fire (pr-stale) + one direct fire (real script) ──
# Single-line to avoid backslash/newline quoting pitfalls in JSON literals.
FIXTURE='{"fired":[{"name":"pr-stale","severity":"P3","evidence":"Open PRs: 3","action":"incident","action_script":"__MISSING__"},{"name":"disk-pressure","severity":"P1","evidence":"Disk: 85% used","action":"direct","action_script":"supervisor/actions/disk-pressure.sh"}]}'

# run_escalation <recipe-output> <set-on>
# Run escalation_off in a throwaway subshell: a fresh shell (so it never
# inherits a SUPERVISOR_LLM_ESCALATION set by an earlier AC), the env set per
# <set-on> ("1" -> on, "0" -> unset/off), the extracted function evaled, then
# the function invoked. Captures the subshell's combined output in OUT and its
# exit status in rc. The inherited top-level log() lands the single line there.
run_escalation() {
  local recipe_output="$1" set_on="$2"
  rc=0
  # A fresh subshell (so it never inherits a SUPERVISOR_LLM_ESCALATION set by
  # an earlier AC), the env set per <set-on> ("1" -> on, "0" -> unset/off),
  # the extracted function evaled, then the function invoked. exec 2>&1 sends
  # the subshell's stderr onto its stdout so both are captured in OUT. The
  # substitution's exit status is the function's, captured via `|| rc=$?`.
  OUT="$(
    exec 2>&1
    if [ "$set_on" = "1" ]; then
      export SUPERVISOR_LLM_ESCALATION="on"
    else
      unset SUPERVISOR_LLM_ESCALATION 2>/dev/null || true
    fi
    eval "$ESCALATION_SRC"
    escalation_off "$recipe_output"
  )" || rc=$?
}

# ── 1. incident fire + variable unset -> 0 + log naming pr-stale ──────────
run_escalation "$FIXTURE" 0
ac_assert_eq "$rc" "0" \
  "unset escalation (default off) with an incident fire must return 0 (got $rc): $OUT"
case "$OUT" in
  *"pr-stale"*) ;;
  *) ac_fail "default-off escalation must log a line naming pr-stale, got: $OUT" ;;
esac
# The log line must be exactly the single template line (one log call, the
# required prefix).
case "$OUT" in
  *"LLM escalation off: 1 fired recipe(s) left for a human: pr-stale"*) ;;
  *) ac_fail "default-off escalation must log the template line naming pr-stale, got: $OUT" ;;
esac

# ── 2. incident fire + SUPERVISOR_LLM_ESCALATION=on -> 1, logs nothing ────
run_escalation "$FIXTURE" 1
ac_assert_eq "$rc" "1" \
  "escalation switched on must return 1 (got $rc): $OUT"
if [ -n "$OUT" ]; then
  ac_fail "escalation switched on must log nothing, got: $OUT"
fi

# ── 3. direct fire with a real action_script is not named ──────────────────
# A fixture with ONLY a direct fire (real script) -> escalation_off is not
# called in the real flow (LLM_REQUIRED would be false), but it must not name
# the direct recipe even when invoked.
DIRECT_ONLY='{"fired":[{"name":"disk-pressure","severity":"P1","evidence":"Disk: 85% used","action":"direct","action_script":"supervisor/actions/disk-pressure.sh"}]}'
run_escalation "$DIRECT_ONLY" 0
# Must still return 0 (bash-only) and log a line; the direct fire is NOT named.
ac_assert_eq "$rc" "0" "a direct-only fire with a real script must still return 0 (got $rc): $OUT"
case "$OUT" in
  *"disk-pressure"*) ac_fail "a direct fire with a real action_script must NOT be named, got: $OUT" ;;
esac
# Count is 0 (nothing left for a human), and pr-stale (not in fixture) is
# absent. The template line with n=0 must appear.
case "$OUT" in
  *"LLM escalation off: 0 fired recipe(s) left for a human:"*) ;;
  *) ac_fail "a direct-only fire must log 0 recipes left for a human, got: $OUT" ;;
esac

ac_pass
