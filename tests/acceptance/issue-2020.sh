#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2020.sh
#
# Issue #2020: fix(sprint): a sprint's effect probe reads the sprint's own
# soak window.
#
# Contract under test (tools/sprint-outcomes.sh, _sprint_one): when effect is
# a path, the probe runs over the sprint's own soak window, the same way
# tools/claim-checks.sh (#1642) passes a claim's window:
#   PROBE_UNTIL        = epoch seconds at the soak's end: the integer epoch in
#                        ${TAPE_DIR}/sprints/<N>.soak (written by
#                        tools/sprint-due.sh) plus the soak's seconds
#   PROBE_WINDOW_S     = the soak's seconds
#   PROBE_WINDOW_DAYS  = those seconds rounded up to days, at least 1
# A missing or non-integer <N>.soak, or a non-integer soak: one log line
# "sprint <N>: soak window unknown — no outcome this run", no outcome, rc 0.
# effect none: unchanged — the probe never runs.
#
# Acceptance (hermetic — no network, stubbed forge_api, fixture probes in a
# temp OPS_REPO_ROOT, temp TAPE_DIR):
#   * AC1 soak: 7d, expect: >= 3, <N>.soak = E (E + 604800 already past):
#     the window log reads "<E+604800> 604800 7" and the outcome has effect: 1.
#   * AC2 soak: 36h: the probe sees PROBE_WINDOW_S 129600, PROBE_WINDOW_DAYS 2.
#   * AC3 effect none: the probe never ran (the window log stays empty) and
#     the outcome follows n_failed as before.
#   * AC4 bash -n passes; shellcheck clean when available; the guard line and
#     the PROBE_UNTIL export are present in the tool.
#
# Run via: tools/run-acceptance.sh 2020
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck source=../../tests/lib/forge-stub.sh
source "$REPO_ROOT/tests/lib/forge-stub.sh"

ac_require_cmd bash jq date mktemp
ac_assert_file "$REPO_ROOT/tools/sprint-outcomes.sh" "tools/sprint-outcomes.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-due.sh" "tools/sprint-due.sh is missing"
ac_assert_file "$REPO_ROOT/tools/sprint-children.sh" "tools/sprint-children.sh is missing"
ac_assert_file "$REPO_ROOT/lib/probe.sh" "lib/probe.sh is missing"
ac_assert_file "$REPO_ROOT/lib/tape.sh" "lib/tape.sh is missing"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS_REPO_ROOT="$TMP_DIR/ops"
export OPS_REPO_ROOT
mkdir -p "$OPS_REPO_ROOT/probes"

STUB_BIN="$TMP_DIR/bin"
FIXTURES="$TMP_DIR/fixtures"
CALLS="$TMP_DIR/calls"
mkdir -p "$STUB_BIN" "$FIXTURES"
: >"$CALLS"

# forge_api stub + write_milestone come from tests/lib/forge-stub.sh.
stub_milestone_forge_api

# Fixture probe (the issue's harness): appends
# "$PROBE_UNTIL $PROBE_WINDOW_S $PROBE_WINDOW_DAYS" to $WINDOW_LOG, prints 5.
# shellcheck disable=SC2154  # WINDOW_LOG is exported by run()
cat >"$OPS_REPO_ROOT/probes/window.sh" <<'EOF'
printf '%s %s %s\n' "${PROBE_UNTIL:-unset}" "${PROBE_WINDOW_S:-unset}" \
  "${PROBE_WINDOW_DAYS:-unset}" >>"${WINDOW_LOG:?}"
echo 5
EOF

# seed_children DIR PARENT ROLES... — one proposal per role, plus a merged or
# rejected outcome for each; "none" means a child with no outcome at all, so
# tools/sprint-children.sh counts it in n_failed.
seed_children() {
  local dir="$1" parent="$2" role i=0 id
  shift 2
  : >"$dir/tape.jsonl"
  for role in "$@"; do
    i=$((i + 1))
    id="c$i"
    jq -cn --arg id "$id" --arg parent "$parent" \
      '{type:"proposal",t:"2026-02-10T00:00:00Z",id:$id,loop:"dev",
        class:"internal",parent:$parent,context:{},decision:"approved",
        ref:"x"}' >>"$dir/tape.jsonl"
    if [ "$role" != "none" ]; then
      jq -cn --arg id "$id" --arg role "$role" \
        '{type:"outcome",t:"2026-02-10T01:00:00Z",proposal_id:$id,
          bits:{($role):1},numbers:{},children:{},payloads:[]}' \
        >>"$dir/tape.jsonl"
    fi
  done
}

# run AC TAPEDIR WINDOWLOG — run the tool against one tape dir. RC, OUT, ERR
# land in globals.
run() {
  local dir="$1" log="$2"
  RC=0
  OUT=""
  ERR=""
  env -u FORGE_API -u FORGE_TOKEN \
    TAPE_DIR="$dir" \
    PATH="$STUB_BIN:${PATH}" \
    FORGE_CALLS="$CALLS" \
    FORGE_FIXTURES="$FIXTURES" \
    WINDOW_LOG="$log" \
    bash "$REPO_ROOT/tools/sprint-outcomes.sh" \
    >"$TMP_DIR/out" 2>"$TMP_DIR/err" || RC=$?
  OUT="$(cat "$TMP_DIR/out" 2>/dev/null || true)"
  ERR="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
}

# outcome_of TAPEDIR PID — the tape's last outcome for PID (or empty).
outcome_of() {
  local dir="$1" pid="$2"
  jq -r -c 'select(.type == "outcome" and .proposal_id == $pid)' \
    --arg pid "$pid" \
    "$dir/tape.jsonl" 2>/dev/null | tail -n 1
}

NOW="$(date -u +%s)"

# ── AC1: soak 7d ending in the past -> the probe reads exactly that window ───
ac_log "AC1: soak 7d, .soak = E -> probe sees '<E+604800> 604800 7', outcome effect 1"
write_milestone 1 closed 0 1 "class: deploy
effect: probes/window.sh
expect: >= 3
soak: 7d"
E1=$((NOW - 604800 - 100))
TAPEDIR="$TMP_DIR/tape-ac1"
mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-1" >"$TAPEDIR/sprints/1"
printf '%s\n' "$E1" >"$TAPEDIR/sprints/1.soak"
: >"$TAPEDIR/window.log"
seed_children "$TAPEDIR" s-1 merged
run "$TAPEDIR" "$TAPEDIR/window.log"
ac_assert_eq "$RC" "0" "AC1: tool must exit 0 (rc=$RC): $OUT"
ac_assert_eq "$(head -n 1 "$TAPEDIR/window.log")" "$((E1 + 604800)) 604800 7" \
  "AC1: the probe window must be the soak window (got: $(head -n 1 "$TAPEDIR/window.log" 2>/dev/null))"
out="$(outcome_of "$TAPEDIR" s-1)"
[ -n "$out" ] || ac_fail "AC1: no outcome for s-1 (stderr: $ERR)"
ac_assert_eq "$(jq -r '.bits.effect' <<<"$out" 2>/dev/null)" "1" \
  "AC1: outcome effect must be 1 (5 >= 3) (got '$out')"
ac_assert_eq "$(jq -r '.numbers.effect_value' <<<"$out" 2>/dev/null)" "5" \
  "AC1: outcome numbers.effect_value must be 5 (got '$out')"
[ -f "$TAPEDIR/sprints/1.done" ] || ac_fail "AC1: $TAPEDIR/sprints/1.done must exist"

# ── AC2: soak 36h -> 129600 seconds, 2 days ──────────────────────────────────
ac_log "AC2: soak 36h -> PROBE_WINDOW_S 129600, PROBE_WINDOW_DAYS 2"
write_milestone 2 closed 0 1 "class: deploy
effect: probes/window.sh
expect: >= 3
soak: 36h"
E2=$((NOW - 129600 - 50))
TAPEDIR="$TMP_DIR/tape-ac2"
mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-2" >"$TAPEDIR/sprints/2"
printf '%s\n' "$E2" >"$TAPEDIR/sprints/2.soak"
: >"$TAPEDIR/window.log"
seed_children "$TAPEDIR" s-2 merged
run "$TAPEDIR" "$TAPEDIR/window.log"
ac_assert_eq "$RC" "0" "AC2: tool must exit 0 (rc=$RC): $OUT"
ac_assert_eq "$(head -n 1 "$TAPEDIR/window.log")" "$((E2 + 129600)) 129600 2" \
  "AC2: 36h is 129600 s, rounded up to 2 days (got: $(head -n 1 "$TAPEDIR/window.log" 2>/dev/null))"

# ── AC3: effect none -> the probe never runs, outcome follows n_failed ────────
ac_log "AC3: effect none -> probe never runs; one child with no outcome -> effect 0"
write_milestone 3 closed 0 1 "class: internal
effect: none
expect: >= 3
soak: 7d"
TAPEDIR="$TMP_DIR/tape-ac3"
mkdir -p "$TAPEDIR/sprints"
printf '%s\n' "s-3" >"$TAPEDIR/sprints/3"
printf '%s\n' "$E1" >"$TAPEDIR/sprints/3.soak"
: >"$TAPEDIR/window.log"
seed_children "$TAPEDIR" s-3 none
run "$TAPEDIR" "$TAPEDIR/window.log"
ac_assert_eq "$RC" "0" "AC3: tool must exit 0 (rc=$RC): $OUT"
if [ -s "$TAPEDIR/window.log" ]; then
  ac_fail "AC3: effect none must never run the probe (window.log: $(cat "$TAPEDIR/window.log"))"
fi
out="$(outcome_of "$TAPEDIR" s-3)"
[ -n "$out" ] || ac_fail "AC3: no outcome for s-3 (stderr: $ERR)"
ac_assert_eq "$(jq -r '.bits.effect' <<<"$out" 2>/dev/null)" "0" \
  "AC3: one failed child -> effect 0 (got '$out')"
[ -f "$TAPEDIR/sprints/3.done" ] || ac_fail "AC3: $TAPEDIR/sprints/3.done must exist"

# ── AC4: the tool parses, is shellcheck-clean, and carries the guard ──────────
ac_log "AC4: bash -n passes, shellcheck clean, soak-window guard present"
bash -n "$REPO_ROOT/tools/sprint-outcomes.sh" \
  || ac_fail "AC4: tools/sprint-outcomes.sh must parse with bash -n"
grep -qF 'soak window unknown — no outcome this run' "$REPO_ROOT/tools/sprint-outcomes.sh" \
  || ac_fail "AC4: the tool must log 'sprint <N>: soak window unknown — no outcome this run'"
grep -qF 'PROBE_UNTIL' "$REPO_ROOT/tools/sprint-outcomes.sh" \
  || ac_fail "AC4: the effect probe must be run with PROBE_UNTIL"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REPO_ROOT/tools/sprint-outcomes.sh" "$REPO_ROOT/lib/probe.sh" \
    || ac_fail "AC4: shellcheck must be clean on tools/sprint-outcomes.sh and lib/probe.sh"
else
  ac_warn "AC4: shellcheck not installed — skipped"
fi

# ── AC5: the test itself must exit 0 and ac_pass ──────────────────────────────
ac_pass "issue #2020: a sprint's effect probe reads the sprint's own soak window"
