#!/usr/bin/env bash
# =============================================================================
# gardener/idle-steps.sh — the bash-only tape steps of a full gardener run,
# run by a gardener tick that has nothing to groom (#2148).
#
# Usage: source gardener/idle-steps.sh   (after lib/env.sh, so log() exists)
#   gardener_idle_steps                  # never fatal: always returns 0
#
# Preconditions: FACTORY_ROOT, PROJECT_REPO_ROOT, FORGE_REMOTE, PRIMARY_BRANCH
# and a log() function.
# =============================================================================

# gardener_idle_steps — the bash-only tape steps of a full run, for a run
# that has nothing to groom (#2148). Same tools, same order, never fatal.
gardener_idle_steps() {
  git -C "$PROJECT_REPO_ROOT" fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" --quiet 2>/dev/null || true
  local step rc
  for step in sprint-outcomes sprint-grades tape-rejections grade-threshold claim-proposals claim-checks; do
    rc=0
    SPRINT_HELD_REF="${FORGE_REMOTE}/${PRIMARY_BRANCH}" "$FACTORY_ROOT/tools/${step}.sh" || rc=$?
    [ "$rc" -eq 0 ] || log "WARNING: ${step}.sh failed (rc=${rc}, idle run)"
  done
  return 0
}
