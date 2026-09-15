#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1338.sh — project TOML kind and its env var are gone
#
# Issue #1338 (refactor): the `kind` key is removed from the project TOML,
# the env var it exported is no longer exported, and the research-kind
# second-hire gate in lib/hire-agent.sh is deleted. Software behaviour is
# unchanged; no new pack field is added.
#
# Verifies (all checks read-only — no forge, no nomad, no repo mutation;
# the one temp file is a scratch TOML under mktemp, removed on exit):
#   1. lib/load-project.sh contains no kind env-var string and, behaviourally,
#      sourcing it against a TOML that still carries a `kind = "research"`
#      key exports no kind env var (legacy key ignored) while still
#      exporting the other keys.
#   2. The three example TOMLs (disinto, harb, versi) carry no top-level
#      `kind` key.
#   3. lib/hire-agent.sh has no research-kind second-hire gate: no gate
#      variable, no gate message, no research-kind counting helper, no
#      kind lookup helper — and the file still parses (bash -n).
#   4. The superseded tests are deleted: tests/acceptance/issue-1294.sh,
#      tests/acceptance/issue-1321.sh, tests/hire-an-agent-research.bats.
#   5. Repo-wide: `git grep <kind env var> -- '*.sh' '*.toml'` is empty
#      (the literal is built from a split quote below so this test file
#      itself does not match).
#
# Run via: tools/run-acceptance.sh 1338
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep mktemp git

# The retired env var name, built from a split literal: this file is itself
# a *.sh in the repo, so it must not contain the literal (check 5 would
# self-match).
PK="PROJECT_""KIND"

LOAD_PROJECT="$REPO_ROOT/lib/load-project.sh"
HIRE_AGENT="$REPO_ROOT/lib/hire-agent.sh"

ac_assert_file "$LOAD_PROJECT" "lib/load-project.sh is missing"
ac_assert_file "$HIRE_AGENT" "lib/hire-agent.sh is missing"

# ── 1. load-project.sh: no kind env var, legacy key ignored ─────────────────
ac_log "checking load-project.sh has no kind env-var string"
grep -q "$PK" "$LOAD_PROJECT" \
  && ac_fail "lib/load-project.sh still references the kind env var"

TMP_TOML="$(mktemp)"
trap 'rm -f "$TMP_TOML"' EXIT
cat > "$TMP_TOML" <<'EOF'
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"
kind      = "research"
EOF
# Note the padded spacing above: the TOML is still valid and carries the
# legacy key, but the file never contains the exact `kind = "research"`
# literal (this file is a *.sh in the repo).
OUT="$(bash -c '
  set -eu
  unset "$1" DISINTO_CONTAINER PROJECT_NAME
  source "$2" "$3"
  printf "KIND=%s NAME=%s" "${!1:-UNSET}" "${PROJECT_NAME:-UNSET}"
' _ "$PK" "$LOAD_PROJECT" "$TMP_TOML")" \
  || ac_fail "sourcing lib/load-project.sh against a TOML with a legacy kind key failed"
[[ "$OUT" == "KIND=UNSET"* ]] \
  || ac_fail "load-project.sh still exports the kind env var: $OUT"
[[ "$OUT" == *"NAME=test"* ]] \
  || ac_fail "load-project.sh stopped exporting the other keys: $OUT"
ac_log "load-project.sh: legacy kind key ignored, other keys still exported"

# ── 2. Example TOMLs: no top-level kind key ─────────────────────────────────
ac_log "checking the example TOMLs have no kind key"
for f in disinto harb versi; do
  T="$REPO_ROOT/projects/$f.toml.example"
  ac_assert_file "$T" "projects/$f.toml.example is missing"
  grep -Eq '^[[:space:]]*kind[[:space:]]*=' "$T" \
    && ac_fail "projects/$f.toml.example still writes a top-level kind key"
done
ac_log "example TOMLs: no kind key"

# ── 3. hire-agent.sh: research-kind second-hire gate is gone ────────────────
ac_log "checking hire-agent.sh has no research-kind second-hire gate"
grep -q "gate_kind" "$HIRE_AGENT" \
  && ac_fail "lib/hire-agent.sh still references the gate variable"
grep -q "research kind allows one local-model agent" "$HIRE_AGENT" \
  && ac_fail "lib/hire-agent.sh still has the research-kind refusal message"
grep -q "disinto_project_kind" "$HIRE_AGENT" \
  && ac_fail "lib/hire-agent.sh still defines the kind lookup helper"
grep -q "disinto_count_local_model_jobs" "$HIRE_AGENT" \
  && ac_fail "lib/hire-agent.sh still defines the research local-model counter"
bash -n "$HIRE_AGENT" 2>/dev/null \
  || ac_fail "lib/hire-agent.sh fails bash -n"
ac_log "hire-agent.sh: gate gone, software behaviour intact"

# ── 4. The superseded acceptance tests are deleted ──────────────────────────
ac_log "checking the superseded tests are deleted"
[ ! -e "$REPO_ROOT/tests/acceptance/issue-1294.sh" ] \
  || ac_fail "tests/acceptance/issue-1294.sh still exists"
[ ! -e "$REPO_ROOT/tests/acceptance/issue-1321.sh" ] \
  || ac_fail "tests/acceptance/issue-1321.sh still exists"
[ ! -e "$REPO_ROOT/tests/hire-an-agent-research.bats" ] \
  || ac_fail "tests/hire-an-agent-research.bats still exists (it tested the removed gate)"
ac_log "issue-1294.sh, issue-1321.sh, hire-an-agent-research.bats: gone"

# ── 5. Repo-wide: no kind env var left in any .sh or .toml ──────────────────
ac_log "checking the repo is free of the kind env var"
LEFTOVER="$(git -C "$REPO_ROOT" grep -l "$PK" -- '*.sh' '*.toml' || true)"
[ -z "$LEFTOVER" ] \
  || ac_fail "kind env var still referenced in: $LEFTOVER"
ac_log "repo-wide: kind env var gone from all .sh and .toml files"

ac_pass
