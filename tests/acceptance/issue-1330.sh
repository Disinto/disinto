#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1330.sh — oak/pick.sh ε-greedy action picker
#
# Issue #1330 (oak tick-learner sprint): one ε-greedy program that prints an
# action name from the weights table:
#   oak/pick.sh WEIGHTS.json LEGAL.json
#   LEGAL.json = {"x_key":"2|0","epsilon":0,"q0":1.0,
#                 "legal":["idle","dev-poll","gardener-step"]}
#   Q[x_key][a] missing → q0 (optimistic). stdout: one action name, newline,
#   nothing else. No exec, no weight updates.
#
# Verifies, against the repo checkout's oak/pick.sh (run against private
# temp files — no live state is touched):
#   1. epsilon=0, unique max Q: picks that action
#   2. epsilon=0, several at q0 and one at 0.04: picks the first q0 action
#      in the legal array
#   3. empty legal list: exit 2
#   4. weights file is not modified (byte-identical, no *.tmp left behind)
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd jq

PICK="$REPO_ROOT/oak/pick.sh"
ac_assert_file "$PICK" "oak/pick.sh must exist in the checkout"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
W="$TMPD/weights.json"
L="$TMPD/legal.json"

printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":["idle","dev-poll","gardener-step"]}' >"$L"

# ── 1. epsilon=0, unique max Q: picks that action ────────────────────────────
ac_log "greedy pick with a unique max Q"
printf '%s' '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"idle":0.3,"dev-poll":0.9,"gardener-step":0.5}}},"inbound":{"V":{"2|0":0.4}}}}' >"$W"

got="$(bash "$PICK" "$W" "$L")"
[ "$(printf '%s\n' "$got" | wc -l)" -eq 1 ] || ac_fail "stdout must be exactly one line, got: $got"
[ "$got" = "dev-poll" ] || ac_fail "epsilon=0 with unique max 0.9 must pick dev-poll, got: $got"

# ── 2. epsilon=0, several at q0 and one at 0.04: first q0 action wins ────────
ac_log "greedy pick with a q0 tie and one demoted action"
printf '%s' '{"q0":1.0,"gvf":{"purpose":{"Q":{"2|0":{"dev-poll":0.04}}},"inbound":{"V":{"2|0":0.4}}}}' >"$W"

got="$(bash "$PICK" "$W" "$L")"
# idle and gardener-step read as q0 = 1.0; idle is first in the legal array.
[ "$got" = "idle" ] || ac_fail "q0 tie must pick the first q0 action in legal (idle), got: $got"

# ── 3. empty legal list: exit 2 ──────────────────────────────────────────────
ac_log "empty legal list must exit 2"
printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":[]}' >"$L"
if bash "$PICK" "$W" "$L" >/dev/null 2>&1; then
  ac_fail "empty legal list must not exit 0"
fi
rc=0
bash "$PICK" "$W" "$L" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || ac_fail "empty legal list must exit 2, got: $rc"

# ── 4. weights file is not modified ──────────────────────────────────────────
ac_log "weights file must be byte-identical after a pick"
printf '%s' '{"x_key":"2|0","epsilon":0,"q0":1.0,"legal":["idle","dev-poll","gardener-step"]}' >"$L"
before="$(sha256sum "$W" | cut -d' ' -f1)"
bash "$PICK" "$W" "$L" >/dev/null
after="$(sha256sum "$W" | cut -d' ' -f1)"
[ "$before" = "$after" ] || ac_fail "oak/pick.sh must not modify the weights file"
[ ! -f "$W.tmp" ] || ac_fail "oak/pick.sh must leave no ${W##*/}.tmp file behind"

echo PASS
