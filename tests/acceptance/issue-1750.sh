#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1750.sh — the review test harness sets CLAUDE_MODEL
#
# Issue #1750: review_run_and_parse() does
#   export CLAUDE_MODEL="${REVIEW_CLAUDE_MODEL:-$CLAUDE_MODEL}"
# under set -u. Every review jobspec sets CLAUDE_MODEL, but
# ac_setup_review_env did not, so the harness users failed in a shell that
# had not exported it:
#
#   tests/lib/review-harness.sh: line 47: CLAUDE_MODEL: unbound variable
#
# The harness now exports CLAUDE_MODEL="${CLAUDE_MODEL:-test-model}".
#
# Acceptance (hermetic — no network, no live agent):
#   * AC1 env -u CLAUDE_MODEL bash tests/acceptance/issue-1164-requeue-on-resource-limit.sh
#     exits 0
#   * AC2 env -u CLAUDE_MODEL bash tests/acceptance/issue-1171-review-env-overrides.sh
#     exits 0
#   * AC3 with CLAUDE_MODEL=foo exported, ac_setup_review_env leaves it as foo
#
# Run via: tools/run-acceptance.sh 1750
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash env

run_unset() {
  local name="$1" script="$2" rc=0 out
  ac_log "env -u CLAUDE_MODEL bash $script"
  out="$(env -u CLAUDE_MODEL bash "$script" 2>&1)" || rc=$?
  ac_assert_eq "$rc" "0" \
    "$name must exit 0 with CLAUDE_MODEL unset (rc=$rc): $out"
  case "$out" in
    *PASS*) ;;
    *) ac_fail "$name did not print PASS with CLAUDE_MODEL unset: $out" ;;
  esac
}

# ── AC1 / AC2: both harness users pass with CLAUDE_MODEL unset ───────────────
run_unset "issue-1164" "$REPO_ROOT/tests/acceptance/issue-1164-requeue-on-resource-limit.sh"
ac_log "AC1 OK: issue-1164 passes with CLAUDE_MODEL unset"
run_unset "issue-1171" "$REPO_ROOT/tests/acceptance/issue-1171-review-env-overrides.sh"
ac_log "AC2 OK: issue-1171 passes with CLAUDE_MODEL unset"

# ── AC3: an already-exported CLAUDE_MODEL is left alone ──────────────────────
ac_log "AC3: harness preserves an exported CLAUDE_MODEL"
preserved="$(
  set -euo pipefail
  # shellcheck source=../../tests/lib/acceptance-helpers.sh
  source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
  # shellcheck source=../../tests/lib/review-harness.sh
  source "$REPO_ROOT/tests/lib/review-harness.sh"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  export CLAUDE_MODEL=foo
  ac_setup_review_env 1750
  printf '%s' "$CLAUDE_MODEL"
)" || ac_fail "ac_setup_review_env failed while CLAUDE_MODEL=foo was exported"
ac_assert_eq "$preserved" "foo" \
  "ac_setup_review_env must leave an exported CLAUDE_MODEL=foo unchanged, got: ${preserved}"
ac_log "AC3 OK: exported CLAUDE_MODEL=foo is preserved"

ac_pass "issue #1750: the review test harness sets CLAUDE_MODEL"
