#!/usr/bin/env bats
# =============================================================================
# tests/lib-formula-worktree-self-heal.bats — Regression guard for #1120 / #551.
#
# Before the self-heal fix, formula_worktree_setup expanded
# "${FORGE_REMOTE}/${PRIMARY_BRANCH}" directly. Under `set -u` (which every
# *-run.sh caller enables via `set -euo pipefail`), an unset FORGE_REMOTE
# aborts the script silently at that line. supervisor-run.sh shipped without
# the required `resolve_forge_remote` call, so every 20-min supervisor tick
# died mid-cycle with no log entry beyond the abnormal-signal line.
#
# The library-side fix makes formula_worktree_setup call resolve_forge_remote
# itself when FORGE_REMOTE is empty. This test verifies that self-heal: we
# source the library with FORGE_REMOTE unset and confirm the function both
# succeeds and populates FORGE_REMOTE from the local git remote.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO="${BATS_TEST_TMPDIR}/repo"
  WT="${BATS_TEST_TMPDIR}/wt"

  mkdir -p "$REPO"
  (
    cd "$REPO"
    git init -q -b main .
    git -c user.email=t@example.invalid -c user.name=t \
      commit --allow-empty -q -m init
    # Add a remote whose host matches FORGE_URL below so that
    # resolve_forge_remote picks it (rather than falling back to "origin").
    git remote add upstream "http://forge.example.invalid/owner/repo"
    # Fake the fetch target so `git worktree add upstream/main` resolves.
    git update-ref refs/remotes/upstream/main HEAD
  )
}

@test "formula_worktree_setup self-heals when FORGE_REMOTE is unset (#1120)" {
  run bash -c "
    set -euo pipefail
    log() { :; }
    export PROJECT_REPO_ROOT='${REPO}'
    export PRIMARY_BRANCH=main
    export FORGE_URL='http://forge.example.invalid'
    unset FORGE_REMOTE
    source '${ROOT}/lib/worktree.sh'
    source '${ROOT}/lib/formula-session.sh'
    # Neutralize the EXIT trap set by formula_worktree_setup so the test
    # harness sees any error from the function itself, not the cleanup.
    formula_worktree_setup '${WT}'
    trap - EXIT
    printf 'FORGE_REMOTE=%s\n' \"\${FORGE_REMOTE}\"
    test -d '${WT}' && printf 'WORKTREE_CREATED=1\n'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'FORGE_REMOTE=upstream'* ]]
  [[ "$output" == *'WORKTREE_CREATED=1'* ]]
}
