#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1228.sh
#
# Issue #1228: no tooling to cut a release — VERSION bump, tagging, pushing,
# waiting for CI images, and checking GHCR package visibility were all manual
# guesswork. tools/cut-release.sh now does it in one command.
#
# Verifies (all checks read-only — no tag, no push, no tree mutation):
#   1. tools/cut-release.sh --help exits 0 and documents the contract.
#   2. `cut-release.sh 0.0.0-test --dry-run` exits 0 (report mode), prints
#      the stage plan, and leaves the tree, HEAD, VERSION, and refs unmutated
#      — the live checkout is a detached-HEAD CI clone, so this must not
#      depend on pre-flight checks passing.
#   3. Anonymous visibility probe: ghcr.io/disinto/agents must be
#      anonymously pullable (current ground truth; #606) — the single source
#      of truth shared with the tool's stage 5.
#
# Run via: tools/run-acceptance.sh 1228
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git curl jq
ac_assert_file "$REPO_ROOT/tools/cut-release.sh" "tools/cut-release.sh is missing"
ac_assert_file "$REPO_ROOT/tests/cut-release.bats" "tests/cut-release.bats is missing"

# ── 1. --help ───────────────────────────────────────────────────────────────
HELP_OUT="$(bash "$REPO_ROOT/tools/cut-release.sh" --help 2>&1)" \
  || ac_fail "tools/cut-release.sh --help exited non-zero"
for tok in "<version>" "--dry-run" "--yes" "--main" "--skip-wait"; do
  grep -q -- "$tok" <<<"$HELP_OUT" || ac_fail "--help output missing: $tok"
done
ac_log "--help OK"

# ── 2. dry-run: plan printed, nothing mutated ───────────────────────────────
BEFORE_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BEFORE_VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
BEFORE_STATUS="$(git -C "$REPO_ROOT" status --porcelain)"

DRY_OUT="$(bash "$REPO_ROOT/tools/cut-release.sh" 0.0.0-test --dry-run 2>&1)" \
  || ac_fail "cut-release.sh 0.0.0-test --dry-run exited non-zero (report mode must exit 0)"
for tok in "Stage 2" "Stage 3" "Stage 4" "Stage 5" "DRY RUN"; do
  grep -q -- "$tok" <<<"$DRY_OUT" || ac_fail "dry-run plan output missing: $tok"
done

AFTER_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
AFTER_VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
AFTER_STATUS="$(git -C "$REPO_ROOT" status --porcelain)"
[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] || ac_fail "dry-run moved HEAD"
[ "$AFTER_VERSION" = "$BEFORE_VERSION" ] || ac_fail "dry-run mutated VERSION"
[ "$AFTER_STATUS" = "$BEFORE_STATUS" ] || ac_fail "dry-run changed the working tree"
[ -z "$(git -C "$REPO_ROOT" tag -l v0.0.0-test)" ] || ac_fail "dry-run created a tag"
ac_log "dry-run OK (plan printed, tree unmutated)"

# ── 3. anonymous visibility probe (ground truth: agents is public) ──────────
PROBE_OUT="$(bash -c "
  set -euo pipefail
  source '$REPO_ROOT/tools/cut-release.sh'
  cr_probe_anonymous_pull agents
")" || ac_fail "anonymous visibility probe for ghcr.io/disinto/agents failed (network?)"
[ "$PROBE_OUT" = "pullable" ] \
  || ac_fail "anonymous pull of ghcr.io/disinto/agents reports '$PROBE_OUT' (expected 'pullable' — is the package still public?)"
ac_log "anonymous visibility probe OK (disinto/agents pullable)"

ac_pass
