#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1922.sh — edge refuses an empty FORGE_URL under Nomad
#
# Issue #1922: under Nomad (NOMAD_ALLOC_ID set) an empty FORGE_URL means the
# forgejo service is not registered. The entrypoint must exit 1 before the
# compose default, and stderr must name the forgejo service. A set FORGE_URL,
# and compose (no NOMAD_ALLOC_ID), are unchanged.
#
# Hermetic: extracts the file head through the check's fi and runs it with
# bash. No container, no network.
#
# Acceptance: `bash tests/acceptance/issue-1922.sh` exits 0 and prints PASS.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk mktemp

SPEC="$REPO_ROOT/docker/edge/entrypoint-edge.sh"
DOC="$REPO_ROOT/nomad/AGENTS.md"
ac_assert_file "$SPEC" "docker/edge/entrypoint-edge.sh must exist"
ac_assert_file "$DOC" "nomad/AGENTS.md must exist"

# shellcheck disable=SC2016  # literal source line, not an expansion
default_line='FORGE_URL="${FORGE_URL:-http://forgejo:3000}"'
default_lineno="$(grep -n -F "$default_line" "$SPEC" | head -n 1 | cut -d: -f1 || true)"
[ -n "$default_lineno" ] || ac_fail "compose FORGE_URL default line missing from entrypoint-edge.sh"

# Head is every line before the default, which must include the check's fi.
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/issue-1922.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT
head_sh="${sandbox}/head.sh"
head -n "$((default_lineno - 1))" "$SPEC" >"$head_sh"

grep -q 'NOMAD_ALLOC_ID' "$head_sh" \
  || ac_fail "Nomad FORGE_URL check is not before the compose default"
grep -q '^fi$' "$head_sh" \
  || ac_fail "extracted head does not include the check's fi"
if grep -q -F "$default_line" "$head_sh"; then
  ac_fail "extracted head must stop before the compose default"
fi

last_line="$(awk 'NF { line = $0 } END { print line }' "$head_sh")"
ac_assert_eq "$last_line" "fi" \
  "extracted head must end at the check's fi (got '${last_line}')"

interpreter="$(command -v bash)"

# Extra args are env assignments passed to env -i. The head is the entrypoint
# from the shebang through the check's fi, so a later default cannot run.
run_head() {
  local transcript="$1"
  shift
  local status=0
  env -i "$@" "$interpreter" "$head_sh" >"$transcript" 2>"${transcript}.err" || status=$?
  printf '%s' "$status"
}

ac_log "NOMAD_ALLOC_ID set and FORGE_URL unset is fatal and names forgejo"
unset_transcript="${sandbox}/unset.out"
unset_status="$(run_head "$unset_transcript" NOMAD_ALLOC_ID=x)"
ac_assert_eq "$unset_status" "1" \
  "empty FORGE_URL under Nomad must exit 1 (got ${unset_status}); err=$(cat "${unset_transcript}.err")"
grep -q 'forgejo' "${unset_transcript}.err" \
  || ac_fail "stderr must name the forgejo service: $(cat "${unset_transcript}.err")"
grep -q 'FATAL' "${unset_transcript}.err" \
  || ac_fail "stderr must include FATAL: $(cat "${unset_transcript}.err")"
if grep -q 'forgejo' "$unset_transcript"; then
  ac_fail "forgejo must be named on stderr, not stdout: $(cat "$unset_transcript")"
fi

ac_log "NOMAD_ALLOC_ID set and FORGE_URL set exits 0"
set_transcript="${sandbox}/set.out"
set_status="$(run_head "$set_transcript" NOMAD_ALLOC_ID=x FORGE_URL=http://1.2.3.4:3000)"
ac_assert_eq "$set_status" "0" \
  "set FORGE_URL under Nomad must exit 0 (got ${set_status}); err=$(cat "${set_transcript}.err")"

ac_log "without NOMAD_ALLOC_ID the check does not fire"
compose_transcript="${sandbox}/compose.out"
compose_status="$(run_head "$compose_transcript")"
ac_assert_eq "$compose_status" "0" \
  "missing NOMAD_ALLOC_ID must exit 0 (got ${compose_status}); err=$(cat "${compose_transcript}.err")"

ac_log "entrypoint parses (bash -n)"
bash -n "$SPEC" || ac_fail "entrypoint-edge.sh fails bash -n"

ac_log "nomad/AGENTS.md edge.hcl row documents the refusal"
# shellcheck disable=SC2016  # backticks are markdown in the required sentence
grep -q -F 'Under Nomad the entrypoint refuses to start when the `forgejo` service is not registered (empty `local/forge.env`), with a FATAL line naming it.' "$DOC" \
  || ac_fail "nomad/AGENTS.md edge.hcl row must document the empty forge.env refusal"

echo PASS
