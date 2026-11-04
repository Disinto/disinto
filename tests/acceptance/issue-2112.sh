#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2112.sh
#
# Issue #2112: tools/rollout.sh moves live and canary by git push, and only to
# commits of the primary branch (docs/design/notes/self-update.md, "Rules the
# tool keeps"). The forge's API cannot move a branch — its PATCH only renames —
# so the tool pushes; DIR is a clone whose `origin` is the disinto repo and the
# primary branch is ${PRIMARY_BRANCH:-main}.
#
#   rollout_heads DIR
#     `timeout 60 git -C DIR ls-remote origin refs/heads/<primary>
#     refs/heads/live refs/heads/canary` -> one line "<main> <live> <canary>"
#     of full SHAs, exit 0. Nothing printed, exit 1, when the command fails or
#     any of the three refs is missing.
#   rollout_on_main DIR SHA
#     Fetch origin/<primary>, then `merge-base --is-ancestor SHA FETCH_HEAD`:
#     0 when SHA is on the primary branch, 1 when it is not or the fetch fails.
#   rollout_move DIR BRANCH SHA [force]
#     BRANCH must be live or canary, and force is allowed only with canary:
#     anything else is 2 with no push. 1 with no push when SHA is not on the
#     primary branch. Otherwise `git push --quiet [--force] origin
#     "SHA:refs/heads/BRANCH"`, returning git's code.
#
# Hermetic: a bare repo as `origin` and a clone as DIR in a temp dir, git only.
# No forge, no network.
#
# Acceptance: `bash tests/acceptance/issue-2112.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git timeout

TOOL="$REPO_ROOT/tools/rollout.sh"
ac_assert_file "$TOOL" "tools/rollout.sh is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issue-2112.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PRIMARY="main"
ORIGIN="$WORK/origin"
DIR="$WORK/clone"

# ── fixture: a bare origin, a clone, M1 and M2 on main, live and canary at M1,
#    X only on a side branch ──────────────────────────────────────────────────
git init -b main --bare "$ORIGIN" >/dev/null
git init -b main "$DIR" >/dev/null
git -C "$DIR" config user.name "rollout-test"
git -C "$DIR" config user.email "rollout-test@example.com"
git -C "$DIR" remote add origin "$ORIGIN"

commit_on() {  # commit_on <branch> <message> -> prints the new SHA
  local branch="$1" message="$2"
  if git -C "$DIR" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git -C "$DIR" checkout --quiet "$branch"
  elif git -C "$DIR" rev-parse --verify --quiet HEAD >/dev/null; then
    git -C "$DIR" checkout --quiet -b "$branch"   # a branch that does not exist yet
  fi
  # else: a fresh repo whose only branch is the primary, already checked out.
  printf '%s\n' "$message" >>"$DIR/history.txt"
  git -C "$DIR" add -A
  git -C "$DIR" commit --quiet -m "$message"
  git -C "$DIR" rev-parse HEAD
}

M1="$(commit_on main "M1")"
git -C "$DIR" push --quiet origin main
git -C "$DIR" push --quiet origin "$M1:refs/heads/live" "$M1:refs/heads/canary"

X="$(commit_on side "X only on side")"
git -C "$DIR" push --quiet origin side
M2="$(commit_on main "M2")"
git -C "$DIR" push --quiet origin main

origin_head() {  # origin_head <branch> -> the SHA origin has for that branch
  git -C "$ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null || echo missing
}

# Run a rollout function by sourcing the tool in a subshell ($0 is a dummy so
# the direct-run guard does not fire). Status in RC, stdout in OUT.
run_fn() {
  local fn="$1"
  shift
  RC=0
  # shellcheck disable=SC2034
  OUT="$(PRIMARY_BRANCH="$PRIMARY" bash -c '
    source "$1"
    "$2" "${@:3}"
  ' _ "$TOOL" "$fn" "$@")" || RC=$?
}

# ── AC1: rollout_heads prints "<main> <live> <canary>" ────────────────────────
run_fn rollout_heads "$DIR"
ac_assert_eq "$RC" 0 "AC1 rollout_heads failed: $OUT"
ac_assert_eq "$OUT" "$M2 $M1 $M1" "AC1 rollout_heads must print M2 M1 M1, got: $OUT"

# canary deleted -> nothing printed, exit 1.
git -C "$ORIGIN" update-ref -d refs/heads/canary
run_fn rollout_heads "$DIR"
ac_assert_eq "$RC" 1 "AC1 rollout_heads must fail when canary is missing, got $RC"
ac_assert_eq "$OUT" "" "AC1 rollout_heads must print nothing when canary is missing, got: $OUT"
git -C "$ORIGIN" update-ref refs/heads/canary "$M1"

# an unreachable origin also fails closed, printing nothing
run_fn rollout_heads "$WORK/not-a-clone"
ac_assert_eq "$RC" 1 "AC1 rollout_heads must fail on a missing clone, got $RC"
ac_assert_eq "$OUT" "" "AC1 rollout_heads must print nothing on a missing clone, got: $OUT"

# ── AC2: rollout_on_main accepts main commits, rejects the side branch ────────
run_fn rollout_on_main "$DIR" "$M1"
ac_assert_eq "$RC" 0 "AC2 M1 is on main, rollout_on_main must return 0, got $RC"
run_fn rollout_on_main "$DIR" "$X"
ac_assert_eq "$RC" 1 "AC2 X only sits on side, rollout_on_main must return 1, got $RC"

# ── AC3: canary moves forward, and backward with force ────────────────────────
run_fn rollout_move "$DIR" canary "$M2"
ac_assert_eq "$RC" 0 "AC3 moving canary to M2 must succeed, got $RC"
ac_assert_eq "$(origin_head canary)" "$M2" "AC3 origin's canary must be M2"

run_fn rollout_move "$DIR" canary "$M1" force
ac_assert_eq "$RC" 0 "AC3 canary may move back to M1 with force, got $RC"
ac_assert_eq "$(origin_head canary)" "$M1" "AC3 forced canary must be M1"

# ── AC4: live moves to M2; a forced move of live is refused ───────────────────
run_fn rollout_move "$DIR" live "$M2"
ac_assert_eq "$RC" 0 "AC4 moving live to M2 must succeed, got $RC"
ac_assert_eq "$(origin_head live)" "$M2" "AC4 origin's live must be M2"

run_fn rollout_move "$DIR" live "$M1" force
ac_assert_eq "$RC" 2 "AC4 live may not be forced, rollout_move must return 2, got $RC"
ac_assert_eq "$(origin_head live)" "$M2" "AC4 live must stay at M2 after a refused forced move"

# ── AC5: a commit off main is refused; the primary branch is not a rollout ref ─
run_fn rollout_move "$DIR" canary "$X"
ac_assert_eq "$RC" 1 "AC5 a commit not on main must be refused with 1, got $RC"
ac_assert_eq "$(origin_head canary)" "$M1" "AC5 canary must be unchanged after a refused move"

run_fn rollout_move "$DIR" main "$M1"
ac_assert_eq "$RC" 2 "AC5 rollout_move must reject a branch that is not live or canary, got $RC"
ac_assert_eq "$(origin_head main)" "$M2" "AC5 main must be untouched by rollout_move"

# ── AC6: bash -n still passes and the direct-run usage guard is intact (#2111) ─
rc=0
bash -n "$TOOL" || rc=$?
ac_assert_eq "$rc" 0 "bash -n tools/rollout.sh must pass"

rc=0
err="$(bash "$TOOL" 2>&1)" || rc=$?
ac_assert_eq "$rc" 2 "running tools/rollout.sh directly must exit 2, got $rc"
ac_assert_eq "$err" "usage: tools/rollout.sh tick" \
  "running tools/rollout.sh directly must print the usage line, got: $err"

ac_pass
