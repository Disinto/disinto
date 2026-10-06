#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1844.sh
#
# Issue #1844: the reproduce sidecar checks out its own clone of the project
# into PROJECT_REPO_ROOT. A later run resets that clone to origin/$PRIMARY_BRANCH
# so a previous triage's edits never leak, and the forge token is passed only
# as a per-command http.extraHeader (never written to .git/config).
#
# Uses a local bare repo only: no forge, no network.
#
# Acceptance:
#   1. The first sidecar_project_checkout clones the repo; after a stray file
#      and a local edit, a second call leaves git status --porcelain empty;
#      git config --get-regexp extraheader prints nothing.
#   2. sidecar_project_checkout appears once in entrypoint-reproduce.sh, and
#      bash -n on that entrypoint succeeds.
#
# Run via: tools/run-acceptance.sh 1844
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git grep

ENTRYPOINT="$REPO_ROOT/docker/reproduce/entrypoint-reproduce.sh"
CHECKOUT="$REPO_ROOT/docker/reproduce/project-checkout.sh"
ac_assert_file "$ENTRYPOINT" "docker/reproduce/entrypoint-reproduce.sh must exist"
ac_assert_file "$CHECKOUT" "docker/reproduce/project-checkout.sh must exist"

ac_log "AC 1: sidecar_project_checkout clones, then resets a dirty tree"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/owner"
git init -q --bare "$tmp/owner/repo.git"
seed="$(mktemp -d)"
git init -q -b main "$seed"
git -C "$seed" config user.email "acceptance@localhost"
git -C "$seed" config user.name "acceptance"
echo "seed" > "$seed/README"
git -C "$seed" add README
git -C "$seed" commit -q -m "seed"
git -C "$seed" remote add origin "$tmp/owner/repo.git"
git -C "$seed" push -q origin main
rm -rf "$seed"

export FORGE_URL="file://$tmp"
export FORGE_REPO="owner/repo"
export PRIMARY_BRANCH="main"
export PROJECT_REPO_ROOT="$tmp/work"
export FORGE_TOKEN="not-written-to-config"

# shellcheck disable=SC1091
source "$CHECKOUT"

sidecar_project_checkout \
  || ac_fail "first sidecar_project_checkout failed to clone"
[ -d "$PROJECT_REPO_ROOT/.git" ] \
  || ac_fail "first sidecar_project_checkout did not clone into PROJECT_REPO_ROOT"
[ "$(git -C "$PROJECT_REPO_ROOT" rev-parse --abbrev-ref HEAD)" = "main" ] \
  || ac_fail "clone is not on main"

echo "local edit" >> "$PROJECT_REPO_ROOT/README"
echo "stray" > "$PROJECT_REPO_ROOT/stray-file"
[ -n "$(git -C "$PROJECT_REPO_ROOT" status --porcelain)" ] \
  || ac_fail "setup did not leave the work tree dirty"

sidecar_project_checkout \
  || ac_fail "second sidecar_project_checkout failed"
porcelain="$(git -C "$PROJECT_REPO_ROOT" status --porcelain)"
[ -z "$porcelain" ] \
  || ac_fail "second checkout left a dirty tree: ${porcelain}"

extraheader="$(git -C "$PROJECT_REPO_ROOT" config --get-regexp extraheader || true)"
[ -z "$extraheader" ] \
  || ac_fail "http.extraHeader was written to .git/config: ${extraheader}"

ac_log "AC 2: entrypoint sources the checkout once and parses"
# shellcheck disable=SC2016
count="$(grep -c 'sidecar_project_checkout' "$ENTRYPOINT" || true)"
ac_assert_eq "$count" "1" \
  "sidecar_project_checkout must appear once in entrypoint-reproduce.sh (got $count)"
bash -n "$ENTRYPOINT" \
  || ac_fail "bash -n docker/reproduce/entrypoint-reproduce.sh failed"

ac_pass
