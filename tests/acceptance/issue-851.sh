#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-851.sh — wiring check for the post-merge acceptance
# pipeline.
#
# Issue #851 adds .woodpecker/acceptance-tests.yml together with two helper
# scripts (tools/discover-closed-issues.sh, tools/comment-on-issue.sh). This
# test proves the pieces are present and the discovery helper actually
# extracts a closing reference. It deliberately does NOT exercise the live
# Woodpecker run (that is verified by the next real merge after this lands).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck disable=SC1091
source tests/lib/acceptance-helpers.sh

ac_require_cmd jq

# ── 1. Pipeline + helpers exist ──────────────────────────────────────────────
[ -f .woodpecker/acceptance-tests.yml ] \
  || ac_fail "pipeline file missing: .woodpecker/acceptance-tests.yml"
[ -x tools/discover-closed-issues.sh ] \
  || ac_fail "discovery tool missing or not executable: tools/discover-closed-issues.sh"
[ -x tools/comment-on-issue.sh ] \
  || ac_fail "comment tool missing or not executable: tools/comment-on-issue.sh"

# ── 2. Pipeline references the new helpers ──────────────────────────────────
# Catches the regression where the YAML is shipped but forgets to wire one
# of the helpers — the helpers exist on disk but the pipeline never invokes
# them, which would silently break the post-merge loop.
grep -q 'discover-closed-issues.sh' .woodpecker/acceptance-tests.yml \
  || ac_fail "pipeline does not invoke tools/discover-closed-issues.sh"
grep -q 'comment-on-issue.sh' .woodpecker/acceptance-tests.yml \
  || ac_fail "pipeline does not invoke tools/comment-on-issue.sh"
grep -q 'run-acceptance.sh' .woodpecker/acceptance-tests.yml \
  || ac_fail "pipeline does not invoke tools/run-acceptance.sh"
grep -q 'awaiting-live-verification' .woodpecker/acceptance-tests.yml \
  || ac_fail "pipeline does not manage the awaiting-live-verification label"

# ── 3. Discovery extracts the self-issue from a fake merge commit ──────────
# Mirrors the AC text from the issue body. The (#PRN) is a literal
# placeholder for the PR number — the discovery tool must NOT match it
# (it should only match closing keywords + a numeric ref).
self_issue=851
fake_merge_msg=$'Merge pull request \'fix: ...\' (#PRN) from x into main\n\nCloses #'"$self_issue"
issues="$(printf '%s' "$fake_merge_msg" | tools/discover-closed-issues.sh)"
echo "$issues" | jq -e --argjson n "$self_issue" '. | index($n) != null' >/dev/null \
  || ac_fail "discovery did not find self-issue $self_issue (got: $issues)"

# ── 4. Discovery rejects non-closing refs ───────────────────────────────────
# A bare `#NNN` outside any closing keyword must NOT show up as a closed
# issue (otherwise every merge would "close" its own PR number from the
# `(#NNN)` in the merge subject).
non_closing="See PR #99999 for context — but this is not a closing ref."
issues2="$(printf '%s' "$non_closing" | tools/discover-closed-issues.sh)"
[ "$issues2" = "[]" ] \
  || ac_fail "discovery surfaced a non-closing ref: $issues2"

# ── 5. (Optional) lint the pipeline YAML ────────────────────────────────────
# woodpecker-cli is not always installed on the box that runs the test.
# When present, use it; when absent, fall back to a minimal yaml lint via
# python so the structural shape (valid YAML) is still checked.
if command -v woodpecker-cli >/dev/null 2>&1; then
  woodpecker-cli lint .woodpecker/acceptance-tests.yml \
    || ac_fail "woodpecker-cli lint rejected .woodpecker/acceptance-tests.yml"
elif command -v python3 >/dev/null 2>&1 \
     && python3 -c "import yaml" >/dev/null 2>&1; then
  python3 -c "import yaml; yaml.safe_load(open('.woodpecker/acceptance-tests.yml'))" \
    || ac_fail ".woodpecker/acceptance-tests.yml is not valid YAML"
else
  ac_warn "neither woodpecker-cli nor python3+pyyaml available — skipping YAML lint"
fi

echo PASS
