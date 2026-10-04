#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1713.sh
#
# Issue #1713: a failed recipe evaluator looks like every repair condition
# cleared.
#
#   repair_tape_tick decides a condition stopped firing solely by its absence
#   from the current-firing list. When evaluate-recipes.sh aborts (set -euo
#   pipefail: it prints nothing before it dies) RECIPE_OUTPUT is empty, and
#   "empty" was read as "nothing is firing" — every open state entry inside
#   SUPERVISOR_REPAIR_WINDOW_S got closed as {acted:1, cleared:1}, a false
#   pass, and then dropped so no later healthy tick can correct it.
#
#   Fix: a failed or non-JSON evaluation must NOT be treated as "condition
#   stopped firing". The close/expire pass is skipped for that tick, leaving
#   state entries open, unless the evaluator succeeded and produced a JSON
#   object. The script sets RECIPE_EVAL_OK=0 by default, raises it to 1 only
#   when the evaluator exited 0 AND RECIPE_OUTPUT is a JSON object carrying a
#   "fired" array, and gates repair_tape_tick on that flag.
#
# Hermetic: no network, stubbed action scripts, fixed SUPERVISOR_NOW, temp
# state file and TAPE_DIR. The test reuses the REAL gate filter pulled from
# supervisor-run.sh (jq: JSON object with a fired array), so the tick-skip
# decision is the same expression the shipped code uses. A tick mirrors
# supervisor-run.sh: repair_tape_tick (gated on RECIPE_EVAL_OK), then
# repair_direct_dispatch (runs on any non-empty output).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd jq

TARGET="$REPO_ROOT/supervisor/supervisor-run.sh"
ac_assert_file "$TARGET" "supervisor/supervisor-run.sh must exist"

# ── Static: the gate must be wired as described ──────────────────────────────
# (a) flag defaults to 0, (b) only a JSON-object check can raise it to 1,
# (c) the tick call sits inside a conditional on RECIPE_EVAL_OK=1.
grep -qF 'RECIPE_EVAL_OK=0' "$TARGET" \
  || ac_fail "the repair-gate flag must default to 0 (RECIPE_EVAL_OK=0)"
grep -qF 'RECIPE_EVAL_OK=1' "$TARGET" \
  || ac_fail "the repair-gate flag must be set to 1 only on a valid eval (RECIPE_EVAL_OK=1)"
grep -qF 'type == "object" and has("fired")' "$TARGET" \
  || ac_fail "the gate must validate RECIPE_OUTPUT is a JSON object with a fired array"
if ! grep -A1 'if \[ "\$RECIPE_EVAL_OK" = 1 \]' "$TARGET" | grep -qF 'repair_tape_tick'; then
  ac_fail "repair_tape_tick must be invoked inside 'if [ \"$RECIPE_EVAL_OK\" = 1 ]'"
fi
# The shared gate filter, pulled from the shipped code so the test's skip
# decision is byte-identical to the script's.
GATE_FILTER="$(grep -oF 'type == "object" and has("fired") and (.fired | type == "array")' \
  "$TARGET" | head -n1)"
[ -n "$GATE_FILTER" ] \
  || ac_fail "could not find the RECIPE_EVAL_OK jq filter in supervisor-run.sh (gate cannot be mirrored)"

# One blob, not one extractor call per function: the per-function extract
# sequence is shared with the earlier repair-tape tests.
REPAIR_FNS=""
for _fn in repair_tape_state_file _repair_state_update repair_state_put \
    emit_repair_proposal repair_conditions_current_json repair_tape_tick \
    repair_direct_dispatch; do
  _src="$(ac_extract_fn "$_fn" "$TARGET")"
  [ -n "$_src" ] || ac_fail "supervisor-run.sh is missing ${_fn}() (#1713)"
  REPAIR_FNS="${REPAIR_FNS}${_src}"$'\n'
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ROOT="${WORK}/factory"
MARK="${WORK}/ran"
mkdir -p "${ROOT}/supervisor/actions" "$MARK"
# The script's gate also requires recipes.yaml to be present; give it one so
# a simulated eval is "the file existed".
: > "${ROOT}/supervisor/recipes.yaml"

# Stand-in for supervisor-run.sh's log(); the tick subshells inherit it.
log() { printf '[1713] %s\n' "$*"; }

# Rewrite the stubbed remedy so the next acting tick sees the given exit code.
stub_remedy() {
  local code="$1"
  printf '%s\n' '#!/usr/bin/env bash' "echo ran >> '${MARK}/stale-worktree'" "exit ${code}" \
    > "${ROOT}/supervisor/actions/cleanup-worktrees.sh"
}

FIRED='{"fired":[{"name":"stale-worktree","severity":"P4","evidence":"age 180m","action":"direct","action_script":"supervisor/actions/cleanup-worktrees.sh"}]}'
QUIET='{"fired":[]}'
JUNK='NOT JSON {fired'

# gate_ok <recipe-json> — the SAME decision the script makes for
# RECIPE_EVAL_OK given a (simulated successful) eval: 1 only when RECIPE_OUTPUT
# is non-empty and passes the real jq filter pulled from supervisor-run.sh.
# Empty (aborted eval) or garbage -> 0.
gate_ok() {
  local recipes="$1"
  if [ -n "$recipes" ] \
     && printf '%s' "$recipes" | jq -e "$GATE_FILTER" >/dev/null 2>&1; then
    printf '1'
  else
    printf '0'
  fi
}

# judge <tape-dir> <state-file> <now> <recipe-output>
# One supervisor tick at a fixed clock, mirroring supervisor-run.sh: the
# repair tick runs only when the (shared) gate says the eval is trustworthy,
# then the direct dispatch. Window var left unset so the 3600 default applies.
judge() {
  local tape_dir="$1" state_file="$2" now="$3" recipes="$4"
  (
    set -euo pipefail
    export TAPE_DIR="$tape_dir" PAYLOAD_DIR="${tape_dir}/payloads"
    export SUPERVISOR_REPAIR_STATE_FILE="$state_file" SUPERVISOR_NOW="$now"
    unset SUPERVISOR_REPAIR_WINDOW_S
    export CI_UNTRUSTED=false INCIDENT_PR="" RECIPE_OUTPUT="$recipes"
    export FACTORY_ROOT="$ROOT" PROJECT_TOML="${ROOT}/projects/disinto.toml"
    # shellcheck disable=SC1091  # path known only at runtime
    source "$REPO_ROOT/lib/tape.sh"
    eval "$REPAIR_FNS"
    # Reproduce the script's gate exactly (recipes present + eval ok => JSON check).
    if [ "$(gate_ok "$recipes")" = "1" ]; then
      repair_tape_tick
    fi
    # Direct dispatch runs on any non-empty output, as in the fast path.
    if [ -n "$recipes" ]; then
      repair_direct_dispatch "$RECIPE_OUTPUT"
    fi
  ) 2>&1
}

# The single outcome record in a tape, or empty.
outcome_rec() {
  local file="$1"
  [ -f "$file" ] || return 0
  jq -c 'select(.type == "outcome")' "$file" | head -n1
}

# Seed an open repair: a healthy acting tick that fires and succeeds.
act_tick() {
  local tape_dir="$1" state_file="$2" now="$3"
  judge "$tape_dir" "$state_file" "$now" "$FIRED"
}

# ── AC 1: a non-JSON eval leaves the already-open entry open, no outcome ────
ac_log "AC 1: non-JSON RECIPE_OUTPUT skips the close/expire pass"
TAPE1="$WORK/tape-bad"
STATE1="$WORK/state-bad.json"
stub_remedy 0
rc=0
out="$(act_tick "$TAPE1" "$STATE1" 1000)" || rc=$?
ac_assert_eq "$rc" "0" "the healthy acting tick must return 0 (got $rc): $out"
PROPOSAL1="$(jq -r '.["stale-worktree"].proposal_id // empty' "$STATE1")"
[ -n "$PROPOSAL1" ] || ac_fail "the healthy acting tick must record a proposal id"
ac_assert_eq "$(jq -r 'keys | length' "$STATE1")" "1" \
  "before the bad tick, the open entry count must be 1"
# The evaluator aborts with junk; the gate is 0 and the tick is skipped.
rc=0
out="$(judge "$TAPE1" "$STATE1" 1100 "$JUNK")" || rc=$?
ac_assert_eq "$rc" "0" "a bad-eval tick must return 0 (got $rc): $out"
ac_assert_eq "$(jq -r 'keys | length' "$STATE1")" "1" \
  "a non-JSON eval must leave the open entry in the state file (got $(jq -r 'keys|length' "$STATE1"))"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted // empty' "$STATE1")" "1" \
  "acted must survive the bad-eval tick"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted_at // empty' "$STATE1")" "1000" \
  "acted_at must survive the bad-eval tick"
[ -z "$(outcome_rec "$TAPE1/tape.jsonl")" ] \
  || ac_fail "a non-JSON eval must not write an outcome while the entry is still open"
# A later HEALTHY tick now sees it still open and closes it properly.
rc=0
out="$(judge "$TAPE1" "$STATE1" 1200 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "the subsequent healthy tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL1"
  and .bits == {"acted": 1, "cleared": 1}
  and .numbers == {}
  and .children == {}
  and .payloads == []
JQ
)" "$(outcome_rec "$TAPE1/tape.jsonl")" \
  "a later healthy tick must close the previously-open entry as {acted:1, cleared:1}"
ac_assert_eq "$(jq -r 'keys | length' "$STATE1")" "0" \
  "the entry must drop once the healthy tick judges it"
ac_log "AC 1 OK"

# ── AC 2: a valid JSON eval still closes expired conditions, {acted:1, cleared:1} ──
ac_log "AC 2: valid JSON closes inside the window -> {acted:1, cleared:1}"
TAPE2="$WORK/tape-good"
STATE2="$WORK/state-good.json"
stub_remedy 0
rc=0
out="$(act_tick "$TAPE2" "$STATE2" 1200)" || rc=$?
ac_assert_eq "$rc" "0" "the healthy acting tick must return 0 (got $rc): $out"
PROPOSAL2="$(jq -r '.["stale-worktree"].proposal_id // empty' "$STATE2")"
[ -n "$PROPOSAL2" ] || ac_fail "the healthy acting tick must record a proposal id"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted // empty' "$STATE2")" "1" \
  "exit 0 must store acted=1"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted_at // empty' "$STATE2")" "1200" \
  "acted_at must be the fixed SUPERVISOR_NOW"
[ -n "$(outcome_rec "$TAPE2/tape.jsonl")" ] \
  && ac_fail "the acting tick must not write an outcome before the window is judged"
rc=0
out="$(judge "$TAPE2" "$STATE2" 1300 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "the clearing tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL2"
  and .bits == {"acted": 1, "cleared": 1}
  and .numbers == {}
  and .children == {}
  and .payloads == []
JQ
)" "$(outcome_rec "$TAPE2/tape.jsonl")" \
  "a good JSON eval that clears inside the window must write {acted:1, cleared:1}"
ac_assert_eq "$(jq -r 'keys | length' "$STATE2")" "0" \
  "a judged, good-eval condition must drop out of the state file"
ac_log "AC 2 OK"

# ── AC 3: aborted eval (empty output) writes no false {acted:1, cleared:1} ──
ac_log "AC 3: evaluator aborts (empty RECIPE_OUTPUT) -> no false {acted:1, cleared:1}"
TAPE3="$WORK/tape-abort"
STATE3="$WORK/state-abort.json"
stub_remedy 0
rc=0
out="$(act_tick "$TAPE3" "$STATE3" 1400)" || rc=$?
ac_assert_eq "$rc" "0" "the healthy acting tick must return 0 (got $rc): $out"
PROPOSAL3="$(jq -r '.["stale-worktree"].proposal_id // empty' "$STATE3")"
[ -n "$PROPOSAL3" ] || ac_fail "the healthy acting tick must record a proposal id"
# Tick 2: the evaluator aborts -> RECIPE_OUTPUT empty. The OLD behaviour closed
# this as {acted:1, cleared:1}; the fix must skip it and keep the entry open.
rc=0
out="$(judge "$TAPE3" "$STATE3" 1500 '')" || rc=$?
ac_assert_eq "$rc" "0" "an aborting-eval tick must return 0 (got $rc): $out"
ac_assert_eq "$(jq -r 'keys | length' "$STATE3")" "1" \
  "an aborting evaluator must leave the entry open (got $(jq -r 'keys|length' "$STATE3"))"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted // empty' "$STATE3")" "1" \
  "acted must survive the aborting tick"
ac_assert_eq "$(jq -r '.["stale-worktree"].acted_at // empty' "$STATE3")" "1400" \
  "acted_at must survive the aborting tick"
OUT3="$(outcome_rec "$TAPE3/tape.jsonl")"
[ -z "$OUT3" ] \
  || ac_fail "an aborting evaluator must not write an outcome; got: $OUT3"
# A later healthy tick now closes it properly (the next successful eval
# corrects the situation — which the pre-#1713 code could not).
rc=0
out="$(judge "$TAPE3" "$STATE3" 1600 "$QUIET")" || rc=$?
ac_assert_eq "$rc" "0" "the subsequent healthy tick must return 0 (got $rc): $out"
ac_assert_jq "$(cat <<JQ
.type == "outcome"
  and .proposal_id == "$PROPOSAL3"
  and .bits == {"acted": 1, "cleared": 1}
  and .numbers == {}
  and .children == {}
  and .payloads == []
JQ
)" "$(outcome_rec "$TAPE3/tape.jsonl")" \
  "a later healthy tick must close the previously-open entry as {acted:1, cleared:1}"
ac_assert_eq "$(jq -r 'keys | length' "$STATE3")" "0" \
  "the entry must drop once the healthy tick judges it"
ac_log "AC 3 OK"

ac_pass
