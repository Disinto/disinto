#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1885.sh
#
# Issue #1885: four stale descriptions match the code.
#
# Read-only greps. Does not reorder code, call the forge, or start a job.
#
# Acceptance: `bash tests/acceptance/issue-1885.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep git

HCL="$REPO_ROOT/nomad/jobs/vault-runner.hcl"
GARDENER_DOC="$REPO_ROOT/gardener/AGENTS.md"
GARDENER="$REPO_ROOT/gardener/gardener-run.sh"
LIB_DOC="$REPO_ROOT/lib/AGENTS.md"
SUPERVISOR_DOC="$REPO_ROOT/supervisor/AGENTS.md"

ac_assert_file "$HCL" "nomad/jobs/vault-runner.hcl is missing"
ac_assert_file "$GARDENER_DOC" "gardener/AGENTS.md is missing"
ac_assert_file "$GARDENER" "gardener/gardener-run.sh is missing"
ac_assert_file "$LIB_DOC" "lib/AGENTS.md is missing"
ac_assert_file "$SUPERVISOR_DOC" "supervisor/AGENTS.md is missing"

# 1. vault-runner.hcl header names the Nomad backend and the live docker path.
ac_log "checking vault-runner.hcl header"
header="$(sed -n '1,12p' "$HCL")"
printf '%s\n' "$header" | grep -qF 'DISPATCHER_BACKEND=nomad' \
  || ac_fail "vault-runner.hcl header must name DISPATCHER_BACKEND=nomad"
printf '%s\n' "$header" | grep -qF 'The live edge uses `docker run`' \
  || ac_fail "vault-runner.hcl header must say the live edge uses docker run"

# 2. gardener/AGENTS.md lists the four tools in gardener-run.sh order.
ac_log "checking gardener tool order in AGENTS.md"
first_line() {
  local hit
  hit="$(grep -nF "$1" "$2" || true)"
  printf '%s\n' "$hit" | awk -F: 'NR==1 { print $1; exit }'
}
so_doc="$(first_line 'tools/sprint-outcomes.sh' "$GARDENER_DOC")"
tr_doc="$(first_line 'tools/tape-rejections.sh' "$GARDENER_DOC")"
cp_doc="$(first_line 'tools/claim-proposals.sh' "$GARDENER_DOC")"
cc_doc="$(first_line 'tools/claim-checks.sh' "$GARDENER_DOC")"
[ -n "$so_doc" ] && [ -n "$tr_doc" ] && [ -n "$cp_doc" ] && [ -n "$cc_doc" ] \
  || ac_fail "gardener/AGENTS.md must name sprint-outcomes, tape-rejections, claim-proposals, and claim-checks"
[ "$so_doc" -lt "$tr_doc" ] && [ "$tr_doc" -lt "$cp_doc" ] && [ "$cp_doc" -lt "$cc_doc" ] \
  || ac_fail "gardener/AGENTS.md tool order is $so_doc $tr_doc $cp_doc $cc_doc, want sprint-outcomes, tape-rejections, claim-proposals, claim-checks"

ac_log "checking the claim-proposals comment no longer says before any sprint tool"
if grep -nF 'before any sprint tool' "$GARDENER"; then
  ac_fail "gardener-run.sh still says before any sprint tool"
fi
grep -qF 'after sprint-outcomes.sh and tape-rejections.sh' "$GARDENER" \
  || ac_fail "claim-proposals comment must say after sprint-outcomes.sh and tape-rejections.sh"

# 3. sprint-filer row requires only the two env vars the script checks.
ac_log "checking the sprint-filer row"
row="$(grep -F '| `lib/sprint-filer.sh`' "$LIB_DOC")"
[ -n "$row" ] || ac_fail "lib/AGENTS.md sprint-filer row is missing"
printf '%s\n' "$row" | grep -qF 'Requires `FORGE_FILER_TOKEN` and `FORGE_API`' \
  || ac_fail "sprint-filer row must say Requires FORGE_FILER_TOKEN and FORGE_API"
ops_count="$(printf '%s\n' "$row" | grep -c 'FORGE_OPS_REPO' || true)"
[ "$ops_count" -eq 0 ] \
  || ac_fail "sprint-filer row still names FORGE_OPS_REPO ($ops_count)"

# 4. supervisor has one trigger; no edge-container loop.
ac_log "checking supervisor/AGENTS.md has no edge-container supervisor loop"
if grep -nE 'entrypoint-edge|edge container|edge-container|two polling loops' "$SUPERVISOR_DOC"; then
  ac_fail "supervisor/AGENTS.md still mentions an edge-container supervisor loop"
fi
grep -qF 'docker/agents/entrypoint.sh' "$SUPERVISOR_DOC" \
  || ac_fail "supervisor/AGENTS.md must name the agents container polling loop"

# 5. git diff on the two code files changes only comment lines.
# After this lands on origin/main the range is empty, so the check is skipped
# and a later code edit to those files does not fail this test.
comment_only_diff() {
  local spec="${1:-}"
  local line body trimmed
  while IFS= read -r line; do
    case "$line" in
      diff\ *|index\ *|---\ *|+++\ *|@@*) continue ;;
    esac
    case "$line" in
      [+-]*)
        body="${line:1}"
        trimmed="${body#"${body%%[![:space:]]*}"}"
        case "$trimmed" in
          ""|\#*) ;;
          *)
            printf '%s\n' "$line"
            return 1
            ;;
        esac
        ;;
    esac
  done < <(git -C "$REPO_ROOT" diff ${spec:+"$spec"} -- nomad/jobs/vault-runner.hcl gardener/gardener-run.sh)
}

ac_log "checking git diff of the two code files is comment-only"
if ! comment_only_diff; then
  ac_fail "working-tree git diff of vault-runner.hcl or gardener-run.sh changes a non-comment line"
fi
if ! comment_only_diff --cached; then
  ac_fail "staged git diff of vault-runner.hcl or gardener-run.sh changes a non-comment line"
fi
if git -C "$REPO_ROOT" rev-parse --verify origin/main >/dev/null 2>&1 \
  && git -C "$REPO_ROOT" log --format=%s origin/main..HEAD | grep -q '#1885'; then
  if ! comment_only_diff origin/main; then
    ac_fail "git diff origin/main of vault-runner.hcl or gardener-run.sh changes a non-comment line"
  fi
  ac_log "origin/main..HEAD diff of the two code files is comment-only"
else
  ac_log "no #1885 commits ahead of origin/main; comment-only range check skipped"
fi

ac_pass "issue #1885: four stale descriptions match the code"
