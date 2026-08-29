#!/usr/bin/env bash
# =============================================================================
# tools/check-deploy-drift.sh — detect drift in the deployed checkout (#1119)
#
# The Nomad jobspecs under nomad/jobs/ are deployed from the deployed checkout
# (DEPLOY_CHECKOUT, default /opt/disinto) — every job reads its jobspec from
# that tree. If the checkout is behind origin/main, merged fixes never reach
# the live cluster; if nomad/ carries uncommitted changes, the deployed
# jobspecs diverge from anything in git.
#
# Drift (exit 1) means either:
#   - the checkout's HEAD is behind ${REMOTE}/${BRANCH} (merged commits that
#     are not in the deployed tree), or
#   - nomad/ has uncommitted changes (modified or untracked files).
#
# Changes outside nomad/ do not count — they are not deployed.
#
# Usage:
#   check-deploy-drift.sh [CHECKOUT] [REMOTE] [BRANCH]
#
#   CHECKOUT  deployed checkout directory (default: ${DEPLOY_CHECKOUT:-/opt/disinto})
#   REMOTE    remote name to compare against (default: origin)
#   BRANCH    branch to compare against (default: main)
#
# Environment:
#   DEPLOY_CHECKOUT       default checkout directory (overridden by $1)
#   DEPLOY_DRIFT_NO_FETCH=1  skip `git fetch` and evaluate the
#                            remote-tracking ref as it currently stands
#                            (offline use, test fixtures).
#
# Exit codes:
#   0  clean — HEAD is not behind and nomad/ has no uncommitted changes
#   1  drift — behind and/or nomad/ dirty
#   2  infrastructure error — checkout missing, not a git repo, unborn HEAD,
#      fetch failed, or the remote-tracking ref is absent
#
# Output: human-readable findings on stdout. The last line is the verdict —
#   VERDICT=clean | VERDICT=drift | VERDICT=error
# — and two machine-readable summary lines:
#   BEHIND=<commit count behind remote branch>
#   DIRTY_FILES=<JSON array of uncommitted paths under nomad/>
# =============================================================================
set -euo pipefail

CHECKOUT="${1:-${DEPLOY_CHECKOUT:-/opt/disinto}}"
REMOTE="${2:-origin}"
BRANCH="${3:-main}"
REF="refs/remotes/${REMOTE}/${BRANCH}"

fail_infra() {
  printf 'deploy-drift: ERROR: %s\n' "$*"
  printf 'VERDICT=error\n'
  exit 2
}

[ -d "$CHECKOUT" ] || fail_infra "checkout ${CHECKOUT} does not exist"
git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1 \
  || fail_infra "checkout ${CHECKOUT} is not a git repository"
git -C "$CHECKOUT" rev-parse --verify HEAD >/dev/null 2>&1 \
  || fail_infra "checkout ${CHECKOUT} has no commits (unborn HEAD)"

# Refresh the remote-tracking ref unless offline.
if [ "${DEPLOY_DRIFT_NO_FETCH:-0}" != "1" ]; then
  git -C "$CHECKOUT" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null \
    || fail_infra "git fetch ${REMOTE} ${BRANCH} failed in ${CHECKOUT}"
fi

git -C "$CHECKOUT" rev-parse --verify --quiet "$REF" >/dev/null \
  || fail_infra "remote-tracking ref ${REF} is not present in ${CHECKOUT}"

# ── Findings ─────────────────────────────────────────────────────────────────
printf 'deploy-drift: checkout=%s remote=%s branch=%s\n' \
  "$CHECKOUT" "$REMOTE" "$BRANCH"

BEHIND=$(git -C "$CHECKOUT" rev-list --count "HEAD..${REMOTE}/${BRANCH}")
DIRTY=$(git -C "$CHECKOUT" status --porcelain -- nomad/)

if [ "$BEHIND" -gt 0 ]; then
  printf 'deploy-drift: HEAD is %s commit(s) behind %s/%s\n' \
    "$BEHIND" "$REMOTE" "$BRANCH"
fi
if [ -n "$DIRTY" ]; then
  printf 'deploy-drift: uncommitted changes under nomad/:\n'
  printf '%s\n' "$DIRTY" | sed 's/^/  /'
fi

# JSON array of the dirty paths (porcelain column 4 onward is the path).
if [ -n "$DIRTY" ]; then
  DIRTY_FILES=$(printf '%s\n' "$DIRTY" | cut -c4- | jq -R . | jq -s -c .)
else
  DIRTY_FILES="[]"
fi

printf 'BEHIND=%s\n' "$BEHIND"
printf 'DIRTY_FILES=%s\n' "$DIRTY_FILES"

DRIFT=0
if [ "$BEHIND" -gt 0 ]; then
  DRIFT=1
fi
if [ -n "$DIRTY" ]; then
  DRIFT=1
fi

if [ "$DRIFT" -eq 1 ]; then
  printf 'VERDICT=drift\n'
  exit 1
fi

printf 'VERDICT=clean\n'
exit 0
