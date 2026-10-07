#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1896.sh
#
# Issue #1896: the Grok reviewer also reviews disinto-admin's PRs.
# Both jobspecs name the same logins, so every PR still has exactly one
# reviewer:
#   agents-review-grok  REVIEW_ONLY_AUTHORS = "dev-grok-bot disinto-admin"
#   agents-review-qwen  REVIEW_SKIP_AUTHORS = "dev-grok-bot disinto-admin"
# pr_author_allowed (lib/pr-author-filter.sh), given those values, admits
# disinto-admin and dev-grok-bot only for the Grok reviewer, and dev-bot
# only for the Qwen reviewer.
#
# Hermetic: no network, no forge, no live box. Reads the jobspecs and
# sources the filter.
#
# Acceptance: `bash tests/acceptance/issue-1896.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep
GROK_HCL="$REPO_ROOT/nomad/jobs/agents-review-grok.hcl"
QWEN_HCL="$REPO_ROOT/nomad/jobs/agents-review-qwen.hcl"
ac_assert_file "$GROK_HCL" "nomad/jobs/agents-review-grok.hcl is missing"
ac_assert_file "$QWEN_HCL" "nomad/jobs/agents-review-qwen.hcl is missing"
ac_assert_file "$REPO_ROOT/lib/pr-author-filter.sh" "lib/pr-author-filter.sh is missing"

# shellcheck source=../../lib/pr-author-filter.sh
source "$REPO_ROOT/lib/pr-author-filter.sh"

# job_env_value KEY FILE — the quoted value of one env assignment.
# Fails unless the key appears exactly once.
job_env_value() {
  local key="$1" file="$2" hits line value
  hits="$(grep -c "^[[:space:]]*${key} = \"" "$file" || true)"
  ac_assert_eq "$hits" "1" \
    "$file must set $key exactly once (got $hits)"
  line="$(grep "^[[:space:]]*${key} = \"" "$file")"
  value="${line#*\"}"
  value="${value%\"*}"
  printf '%s' "$value"
}

GROK_ONLY="$(job_env_value REVIEW_ONLY_AUTHORS "$GROK_HCL")"
QWEN_SKIP="$(job_env_value REVIEW_SKIP_AUTHORS "$QWEN_HCL")"
ac_assert_eq "$GROK_ONLY" "dev-grok-bot disinto-admin" \
  "agents-review-grok REVIEW_ONLY_AUTHORS must be \"dev-grok-bot disinto-admin\" (got $GROK_ONLY)"
ac_assert_eq "$QWEN_SKIP" "dev-grok-bot disinto-admin" \
  "agents-review-qwen REVIEW_SKIP_AUTHORS must be \"dev-grok-bot disinto-admin\" (got $QWEN_SKIP)"

# allowed_rc REVIEWER LOGIN — return code of pr_author_allowed under that
# reviewer's jobspec env. A return of 1 must not trip set -e.
allowed_rc() {
  local reviewer="$1" login="$2" rc=0
  (
    unset REVIEW_ONLY_AUTHORS REVIEW_SKIP_AUTHORS
    case "$reviewer" in
      grok) export REVIEW_ONLY_AUTHORS="$GROK_ONLY" ;;
      qwen) export REVIEW_SKIP_AUTHORS="$QWEN_SKIP" ;;
      *) exit 2 ;;
    esac
    pr_author_allowed "$login"
  ) || rc=$?
  printf '%s' "$rc"
}

ac_log "disinto-admin is admitted only by the Grok reviewer"
ac_assert_eq "$(allowed_rc grok disinto-admin)" "0" \
  "Grok reviewer must admit disinto-admin"
ac_assert_eq "$(allowed_rc qwen disinto-admin)" "1" \
  "Qwen reviewer must refuse disinto-admin"

ac_log "dev-bot is admitted only by the Qwen reviewer"
ac_assert_eq "$(allowed_rc grok dev-bot)" "1" \
  "Grok reviewer must refuse dev-bot"
ac_assert_eq "$(allowed_rc qwen dev-bot)" "0" \
  "Qwen reviewer must admit dev-bot"

ac_log "dev-grok-bot is admitted only by the Grok reviewer"
ac_assert_eq "$(allowed_rc grok dev-grok-bot)" "0" \
  "Grok reviewer must admit dev-grok-bot"
ac_assert_eq "$(allowed_rc qwen dev-grok-bot)" "1" \
  "Qwen reviewer must refuse dev-grok-bot"

ac_pass "issue #1896: the Grok reviewer also reviews disinto-admin's PRs"
