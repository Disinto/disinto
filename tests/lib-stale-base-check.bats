#!/usr/bin/env bats
# tests/lib-stale-base-check.bats — Tests for lib/stale-base-check.sh
#
# Covers the PR #855 scenario: a PR based on stale main whose merged result
# would silently revert upstream changes. Verifies both the true-positive
# (revert) and false-positive (legitimate edit on shared lines) cases.

load '../lib/stale-base-check.sh'

setup() {
  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q -b main .
  git config user.email "test@example.com"
  git config user.name "Test"
  git config commit.gpgsign false
}

teardown() {
  cd /
  rm -rf "$REPO"
}

# Helper: write a file and stage it
_write() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
}

# --- True-positive: the #855 scenario ---

@test "flags file when PR is missing upstream-added lines (revert scenario)" {
  # Initial commit (merge-base for the PR)
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "set -euo pipefail" \
    "echo starting"
  git add entrypoint.sh
  git commit -q -m "initial entrypoint"

  # PR branch off this base — PR makes a small unrelated change
  git checkout -q -b pr-stale
  _write README.md "PR adds a readme"
  git add README.md
  git commit -q -m "pr: add readme"

  # PR also touches entrypoint.sh in a trivial way (so the file is in the
  # PR's diff and a clean merge would NOT auto-take main's version)
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "set -euo pipefail" \
    "echo starting (pr touch)"
  git add entrypoint.sh
  git commit -q -m "pr: trivial entrypoint touch"

  # Meanwhile, main lands a substantial feature on entrypoint.sh
  git checkout -q main
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "set -euo pipefail" \
    "echo starting" \
    "run_planner_iteration" \
    "run_predictor_iteration" \
    "run_gardener_iteration" \
    "run_supervisor_iteration"
  git add entrypoint.sh
  git commit -q -m "main: per-iteration loops"

  # Run the check: PR head vs current main
  local out
  out=$(stale_base_check pr-stale main)
  [[ "$out" == *"entrypoint.sh"* ]]
  # Expect total=4 meaningful upstream-added lines, all missing from PR-head
  [[ "$out" == *"missing=4"* ]]
  [[ "$out" == *"total=4"* ]]
  [[ "$out" == *"pct=100"* ]]
}

# --- False-positive guard ---

@test "does not flag when PR legitimately edits the same upstream-changed lines" {
  # Initial: entrypoint.sh has a single command
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "echo a"
  git add entrypoint.sh
  git commit -q -m "initial"

  # PR branch: changes entrypoint.sh to add new commands (its own additions)
  git checkout -q -b pr-edits
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "echo a" \
    "run_planner_iteration" \
    "run_predictor_iteration" \
    "run_gardener_iteration" \
    "run_supervisor_iteration"
  git add entrypoint.sh
  git commit -q -m "pr: add iteration loops"

  # Main also adds the same iteration loops (race / parallel work)
  git checkout -q main
  _write entrypoint.sh \
    "#!/usr/bin/env bash" \
    "echo a" \
    "run_planner_iteration" \
    "run_predictor_iteration" \
    "run_gardener_iteration" \
    "run_supervisor_iteration"
  git add entrypoint.sh
  git commit -q -m "main: add iteration loops"

  # Both branches have the same upstream-added lines — no revert
  local out
  out=$(stale_base_check pr-edits main)
  [ -z "$out" ]
}

@test "does not flag when PR doesn't touch the upstream-modified file" {
  # Initial
  _write a.sh "echo old"
  _write b.sh "echo b"
  git add a.sh b.sh
  git commit -q -m "initial"

  # PR only touches b.sh
  git checkout -q -b pr-other
  _write b.sh "echo b changed by pr"
  git add b.sh
  git commit -q -m "pr: touch b"

  # Main modifies a.sh
  git checkout -q main
  _write a.sh \
    "echo old" \
    "echo new upstream line 1" \
    "echo new upstream line 2"
  git add a.sh
  git commit -q -m "main: touch a"

  # PR doesn't touch a.sh — clean merge will keep main's version, no revert
  local out
  out=$(stale_base_check pr-other main)
  [ -z "$out" ]
}

@test "does not flag when nothing changed upstream since merge-base" {
  _write a.sh "echo old"
  git add a.sh
  git commit -q -m "initial"

  git checkout -q -b pr-no-upstream
  _write a.sh "echo pr changed"
  git add a.sh
  git commit -q -m "pr: change a"

  # main hasn't moved — merge-base equals main HEAD
  local out
  out=$(stale_base_check pr-no-upstream main)
  [ -z "$out" ]
}

@test "flags multiple files when several upstream changes were reverted" {
  # Simulate the literal PR #855 shape: two files reverted
  _write entrypoint.sh "echo entrypoint v1"
  _write dev-poll.sh "echo dev-poll v1"
  git add entrypoint.sh dev-poll.sh
  git commit -q -m "initial"

  # PR keeps both files at v1 but touches them trivially (whitespace tweak)
  git checkout -q -b pr-stale
  _write entrypoint.sh "echo entrypoint v1 " # trailing space
  _write dev-poll.sh "echo dev-poll v1 "
  git add entrypoint.sh dev-poll.sh
  git commit -q -m "pr: whitespace"

  # Main upgrades both files substantially
  git checkout -q main
  _write entrypoint.sh \
    "echo entrypoint v1" \
    "run_planner_iteration" \
    "run_predictor_iteration" \
    "run_gardener_iteration"
  _write dev-poll.sh \
    "echo dev-poll v1" \
    "source lib/ci-fix-tracker.sh" \
    "ci_fix_tracker_init"
  git add entrypoint.sh dev-poll.sh
  git commit -q -m "main: upgrade both files"

  local out
  out=$(stale_base_check pr-stale main)
  [[ "$out" == *"entrypoint.sh"* ]]
  [[ "$out" == *"dev-poll.sh"* ]]
}

# --- API surface ---

@test "stale_base_check returns 0 when refs are missing" {
  _write a.sh "echo a"
  git add a.sh
  git commit -q -m "initial"

  # No such ref — must not error, just produce no output
  run stale_base_check missing-ref main
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale_base_check_format produces a markdown bullet list" {
  local input='entrypoint.sh|missing=3|total=3|pct=100
dev-poll.sh|missing=2|total=2|pct=100'
  local out
  out=$(stale_base_check_format "$input")
  [[ "$out" == *'- `entrypoint.sh` —'* ]]
  [[ "$out" == *'- `dev-poll.sh` —'* ]]
  [[ "$out" == *'missing=3'* ]]
}

@test "stale_base_check_format empty input produces empty output" {
  local out
  out=$(stale_base_check_format "")
  [ -z "$out" ]
}

@test "respects threshold percentage argument" {
  # Initial
  _write a.sh "echo old"
  git add a.sh
  git commit -q -m "initial"

  # PR keeps half of upstream's additions
  git checkout -q -b pr-half
  _write a.sh \
    "echo old" \
    "echo upstream-line-1" \
    "echo upstream-line-2"
  git add a.sh
  git commit -q -m "pr: keep two of four"

  # Main adds 4 lines; PR has 2 of them, missing 2
  git checkout -q main
  _write a.sh \
    "echo old" \
    "echo upstream-line-1" \
    "echo upstream-line-2" \
    "echo upstream-line-3" \
    "echo upstream-line-4"
  git add a.sh
  git commit -q -m "main: add four"

  # Default threshold (50): 50% missing → exactly at threshold → flag
  local out
  out=$(stale_base_check pr-half main 50)
  [[ "$out" == *"a.sh"* ]]

  # Stricter threshold (80): 50% missing → below threshold → no flag
  out=$(stale_base_check pr-half main 80)
  [ -z "$out" ]
}
