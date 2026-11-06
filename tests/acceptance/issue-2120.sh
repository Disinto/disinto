#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2120.sh
#
# Issue #2120: lib/wall.sh, the wall — the forge's protected file patterns on
# `main` of both repos (docs/design/notes/self-update.md, "The wall").
#
#   wall_patterns KIND   — KIND's list joined by ';' (disinto or ops); any
#                          other KIND returns 1.
#   wall_hits KIND       — paths on stdin (one per line) that match a pattern
#                          of KIND, in input order.
#   wall_apply REPO KIND — disinto: branch_rule_apply REPO main with JSON
#                          whose only key is protected_file_patterns; ops: the
#                          rule keeps direct pushes open (enable_push true).
#   Run directly: lib/wall.sh apply <owner/repo> <disinto|ops>; anything else
#   prints usage and exits 2.
#
# Hermetic: lib/wall.sh is sourced in throwaway subshells; for wall_apply the
# stub branch_rule_apply records "<repo>|<rule>|<json>" one call per line. No
# forge, no network.
#
# Acceptance:
#   1. wall_patterns disinto prints the disinto list; wall_patterns ops the
#      ops list; wall_patterns x returns 1.
#   2. the five-path example prints the 2nd, 3rd and 4th lines; an ops-kind
#      path not in the disinto list is not a disinto hit.
#   3. with a stubbed branch_rule_apply, wall_apply o/r disinto passes rule
#      main and JSON whose only key is protected_file_patterns; wall_apply
#      o/r ops passes JSON with enable_push true.
#   4. bash lib/wall.sh exits 2 (usage, nothing run); bash -n passes.
#
# Run via `tools/run-acceptance.sh 2120` or `bash tests/acceptance/issue-2120.sh`.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq

WALL="$REPO_ROOT/lib/wall.sh"
ac_assert_file "$WALL" "lib/wall.sh is missing"

DISINTO_LIST='tools/sprint-grades.sh;tools/sprint-held.sh;tools/grade.sh;tools/grade-threshold.sh;lib/sprint-block.sh;lib/repair-suspend.sh;action-vault/policy.toml;tools/rollout.sh;.woodpecker/*.yml;docs/design/**'
OPS_LIST='vault/policy.toml;packs/repair.toml;packs/rollout.toml'

# run_wall CMD... — source lib/wall.sh in a throwaway subshell and run CMD.
run_wall() {
  WALL="$WALL" bash -c 'set -euo pipefail; source "$WALL"; "$@"' bash "$@"
}

# ── AC1: the two lists, and an unknown kind ──────────────────────────────────
rc=0
out="$(run_wall wall_patterns disinto)" || rc=$?
ac_assert_eq "$rc" "0" "wall_patterns disinto must succeed (got rc $rc)"
ac_assert_eq "$out" "$DISINTO_LIST" "wall_patterns disinto must print the disinto list"

rc=0
out="$(run_wall wall_patterns ops)" || rc=$?
ac_assert_eq "$rc" "0" "wall_patterns ops must succeed (got rc $rc)"
ac_assert_eq "$out" "$OPS_LIST" "wall_patterns ops must print the ops list"

rc=0
out="$(run_wall wall_patterns x)" || rc=$?
ac_assert_eq "$rc" "1" "wall_patterns x must return 1 (got $rc)"
ac_assert_eq "$out" "" "wall_patterns x must print nothing"

# ── AC2: wall_hits picks the walled paths, in input order ────────────────────
rc=0
out="$(printf '%s\n' README.md tools/rollout.sh .woodpecker/ci.yml docs/design/notes/a.md docs/x.md .woodpecker/agent-smoke.sh \
  | WALL="$WALL" bash -c 'set -euo pipefail; source "$WALL"; wall_hits disinto')" || rc=$?
ac_assert_eq "$rc" "0" "wall_hits disinto must succeed (got rc $rc)"
expected="$(printf 'tools/rollout.sh\n.woodpecker/ci.yml\ndocs/design/notes/a.md')"
ac_assert_eq "$out" "$expected" "wall_hits disinto must print the 2nd, 3rd and 4th lines"

rc=0
out="$(printf '%s\n' vault/policy.toml packs/other.toml packs/repair.toml README.md \
  | WALL="$WALL" bash -c 'set -euo pipefail; source "$WALL"; wall_hits ops')" || rc=$?
ac_assert_eq "$rc" "0" "wall_hits ops must succeed (got rc $rc)"
expected="$(printf 'vault/policy.toml\npacks/repair.toml')"
ac_assert_eq "$out" "$expected" "wall_hits ops must print only the walled paths"

rc=0
out="$(printf '%s\n' packs/repair.toml | WALL="$WALL" bash -c 'set -euo pipefail; source "$WALL"; wall_hits x')" || rc=$?
ac_assert_eq "$rc" "1" "wall_hits with an unknown kind must return 1 (got $rc)"

# ── AC3: wall_apply, with branch_rule_apply stubbed ──────────────────────────
STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issue-2120.XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT
CALLS="$STUB_DIR/calls.txt"
: > "$CALLS"

rc=0
out="$(STUB_CALLS="$CALLS" WALL="$WALL" bash -c '
  set -euo pipefail
  source "$WALL"
  # Stub: record "<repo>|<rule>|<json>" per call, always succeed.
  branch_rule_apply() {
    printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$STUB_CALLS"
    return 0
  }
  wall_apply o/r disinto
  wall_apply o/r ops
  wall_apply o/r zzz || true
')" || rc=$?
ac_assert_eq "$rc" "0" "the stub run must complete (got rc $rc; out: $out)"

disinto_call="$(head -n1 "$CALLS")"
ops_call="$(sed -n '2p' "$CALLS")"
disinto_repo="${disinto_call%%|*}"
disinto_rule="${disinto_call#*|}"
disinto_rule="${disinto_rule%%|*}"
disinto_json="${disinto_call#*|*|}"
ops_repo="${ops_call%%|*}"
ops_rule="${ops_call#*|}"
ops_rule="${ops_rule%%|*}"
ops_json="${ops_call#*|*|}"

ac_assert_eq "$disinto_repo" "o/r" "wall_apply o/r disinto must pass the repo o/r"
ac_assert_eq "$disinto_rule" "main" "wall_apply o/r disinto must pass the rule main"
ac_assert_jq 'keys == ["protected_file_patterns"]' "$disinto_json" \
  "the disinto rule JSON must have only protected_file_patterns"
ac_assert_jq ".protected_file_patterns == \"$DISINTO_LIST\"" "$disinto_json" \
  "the disinto rule JSON must carry the disinto list"

ac_assert_eq "$ops_repo" "o/r" "wall_apply o/r ops must pass the repo o/r"
ac_assert_eq "$ops_rule" "main" "wall_apply o/r ops must pass the rule main"
ac_assert_jq '.enable_push == true' "$ops_json" \
  "the ops rule JSON must keep direct pushes open (enable_push true)"
ac_assert_jq ".protected_file_patterns == \"$OPS_LIST\"" "$ops_json" \
  "the ops rule JSON must carry the ops list"

# An unknown kind reaches no rule at all: only the two stubbed calls landed.
ac_assert_eq "$(wc -l < "$CALLS" | tr -d '[:space:]')" "2" \
  "wall_apply with an unknown kind must not call branch_rule_apply"

# ── AC4: run directly, anything but apply prints usage and exits 2 ───────────
bash -n "$WALL" || ac_fail "bash -n lib/wall.sh must pass"

rc=0
usage="$(bash "$WALL" 2>/dev/null)" || rc=$?
ac_assert_eq "$rc" "2" "lib/wall.sh with no arguments must exit 2 (got $rc)"

rc=0
usage="$(bash "$WALL" frobnicate o/r disinto 2>/dev/null)" || rc=$?
ac_assert_eq "$rc" "2" "lib/wall.sh with an unknown command must exit 2 (got $rc)"

rc=0
usage="$(bash "$WALL" apply 2>/dev/null)" || rc=$?
ac_assert_eq "$rc" "2" "lib/wall.sh apply without both arguments must exit 2 (got $rc)"

usage="$(bash "$WALL" 2>&1 >/dev/null)" || true
case "$usage" in
  *apply*) ;;
  *) ac_fail "usage must name the apply command, got: $usage" ;;
esac

echo PASS
