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
    "source lib/stale-base-check.sh"
  git add entrypoint.sh dev-poll.sh
  git commit -q -m "main: add features to both files"

  # Run the check
  local out
  out=$(stale_base_check pr-stale main)
  [[ "$out" == *"entrypoint.sh"* ]]
  [[ "$out" == *"dev-poll.sh"* ]]
  # entrypoint.sh: 3 upstream-added lines, all missing
  [[ "$out" == *"entrypoint.sh"*"missing=3"* ]]
  # dev-poll.sh: 2 upstream-added lines, all missing
  [[ "$out" == *"dev-poll.sh"*"missing=2"* ]]
}

@test "does not flag when PR contains most upstream-added lines (below threshold)" {
  _write a.sh "echo old"
  git add a.sh
  git commit -q -m "initial"

  git checkout -q -b pr-partial
  # PR changes the file slightly but keeps most of the upstream lines
  _write a.sh "echo old"
  _write note.md "pr note"
  git add a.sh note.md
  git commit -q -m "pr: touch"

  git checkout -q main
  _write a.sh \
    "echo old" \
    "line1" \
    "line2" \
    "line3" \
    "line4" \
    "line5"
  git add a.sh
  git commit -q -m "main: add lines"

  git checkout -q pr-partial
  # PR keeps lines 1-4 but drops line 5 (20% missing, below 50% threshold)
  _write a.sh \
    "echo old" \
    "line1" \
    "line2" \
    "line3" \
    "line4"
  git add a.sh
  git commit -q -m "pr: partial overlap"

  local out
  out=$(stale_base_check pr-partial main)
  [ -z "$out" ]
}

@test "respects custom threshold parameter" {
  _write a.sh "echo old"
  git add a.sh
  git commit -q -m "initial"

  git checkout -q -b pr-low-miss
  _write a.sh "echo old"
  _write note.md "pr note"
  git add a.sh note.md
  git commit -q -m "pr: touch"

  git checkout -q main
  _write a.sh \
    "echo old" \
    "line1" \
    "line2"
  git add a.sh
  git commit -q -m "main: add lines"

  git checkout -q pr-low-miss
  # Trivial change to a.sh so it appears in the PR diff (otherwise --quiet skips it)
  _write a.sh "echo old "
  _write note2.md "pr note2"
  git add a.sh note2.md
  git commit -q -m "pr: no overlap"

  # With 50% threshold: 2/2 missing = 100%, should flag
  local out
  out=$(stale_base_check pr-low-miss main 50)
  [[ "$out" == *"a.sh"* ]]

  # With 100% threshold: same result, should still flag
  out=$(stale_base_check pr-low-miss main 100)
  [[ "$out" == *"a.sh"* ]]

  # With 200% threshold: 100% < 200%, should NOT flag
  out=$(stale_base_check pr-low-miss main 200)
  [ -z "$out" ]
}

@test "stale_base_check_format produces readable output" {
  local input='entrypoint.sh|missing=4|total=4|pct=100
dev-poll.sh|missing=2|total=2|pct=100'
  local formatted
  formatted=$(stale_base_check_format "$input")
  [[ "$formatted" == *"- \`entrypoint.sh\`"* ]]
  [[ "$formatted" == *"- \`dev-poll.sh\`"* ]]
  [[ "$formatted" == *"missing=4"* ]]
}

@test "stale_base_check_format handles empty input" {
  local formatted
  formatted=$(stale_base_check_format "")
  [ -z "$formatted" ]
}

@test "stale_base_check handles bad refs gracefully" {
  local out
  out=$(stale_base_check "nonexistent-ref" "main" 2>/dev/null || true)
  [ -z "$out" ]
}
