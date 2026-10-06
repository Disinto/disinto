#!/usr/bin/env bash
# shellcheck disable=SC2154  # bats_rc/bats_out set by ac_run_bats_suite
# =============================================================================
# tests/acceptance/issue-1854.sh
#
# Issue #1854: an [agents.<name>] section with no `harness` key now renders a
# dsh service on the compose side; Claude is opt-in via harness = "claude".
#
# Before: the compose generator's absent-key fallback rendered the Claude env
# block, so a key-less local-model section ran Claude by accident.
#
# After:
#   1. A key-less (or non-claude) section emits the dsh env block in
#      compose-default.yml; an explicit harness = "claude" emits the Claude
#      block in compose-claude.yml.
#   2. The inline python the hire writes back always records the harness key,
#      with context_window only on the dsh path.
#   3. tests/hire-an-agent-harness.bats passes.
#   4. this test exits 0 via ac_pass.
#
# Run via: tools/run-acceptance.sh 1854
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep awk bats python3

DEFAULT_FIXTURE="$REPO_ROOT/tests/fixtures/hire-an-agent-harness/compose-default.yml"
CLAUDE_FIXTURE="$REPO_ROOT/tests/fixtures/hire-an-agent-harness/compose-claude.yml"
HIRE_LIB="$REPO_ROOT/lib/hire-agent.sh"
HIRE_SUITE="$REPO_ROOT/tests/hire-an-agent-harness.bats"
ac_assert_file "$DEFAULT_FIXTURE" "compose-default.yml must exist"
ac_assert_file "$CLAUDE_FIXTURE" "compose-claude.yml must exist"
ac_assert_file "$HIRE_LIB" "lib/hire-agent.sh must exist"
ac_assert_file "$HIRE_SUITE" "hire suite must exist"

# ── 1. Compose fixtures pin the harness split ────────────────────────────────
ac_log "AC 1: compose fixtures pin dsh (key-less) and claude (opt-in)"
grep -qF 'AGENT_HARNESS: "dsh"' "$DEFAULT_FIXTURE" \
  || ac_fail "compose-default.yml must carry the dsh harness marker"
grep -qF 'AGENT_HARNESS: "claude"' "$CLAUDE_FIXTURE" \
  || ac_fail "compose-claude.yml must carry the claude harness marker"

# A key-less section must not leak Claude tuning variables into its env block.
# Scope the check to service environment entries only (six spaces, then the
# variable name) so the mounted CLAUDE_* volume entries are not counted.
dsh_env_hits="$(grep -Ec '^[[:space:]]{6}(CLAUDE_|ANTHROPIC_)' "$DEFAULT_FIXTURE" || true)"
ac_assert_eq "$dsh_env_hits" "0" \
  "compose-default.yml must have no CLAUDE_/ANTHROPIC_ env entries (found $dsh_env_hits)"
ac_log "AC 1 OK: key-less renders dsh, claude key renders claude"

# ── 2. The hire's inline python always writes the harness key ────────────────
ac_log "AC 2: inline python records harness for both paths"
# Pull the inline program out of lib/hire-agent.sh — the lines between the
# `python3 -c '` header and the quoted argv line.
prog_src="$(awk '/^    python3 -c /{f=1; next} /^'"'"' "\$toml_file"/{exit} f' "$HIRE_LIB")"
[ -n "$prog_src" ] || ac_fail "could not extract the inline python from $HIRE_LIB"

tmp_dsh="$(mktemp --tmpdir)"
tmp_claude="$(mktemp --tmpdir)"
: > "$tmp_dsh"
: > "$tmp_claude"
printf '%s' '[agents.lab]
base_url      = "http://10.0.0.1:8081"
model         = "qwen"
api_key       = "sk-no-key-required"
roles         = ["dev"]
forge_user    = "labbot"
compact_pct   = 60
poll_interval = 60
' > "$tmp_dsh"
cp "$tmp_dsh" "$tmp_claude"

# dsh path: always records the key and the context window.
python3 -c "$prog_src" "$tmp_dsh" labbot "http://10.0.0.1:8081" qwen lab dev 60 dsh 100000 \
  || ac_fail "inline python crashed on the dsh path"
grep -q '^harness = "dsh"' "$tmp_dsh" \
  || ac_fail "dsh path must write harness = \"dsh\""
grep -q '^context_window = 100000$' "$tmp_dsh" \
  || ac_fail "dsh path must write context_window = 100000"

# claude path: records the key, omits the context window.
python3 -c "$prog_src" "$tmp_claude" labbot "http://10.0.0.1:8081" qwen lab dev 60 claude 100000 \
  || ac_fail "inline python crashed on the claude path"
grep -q '^harness = "claude"' "$tmp_claude" \
  || ac_fail "claude path must write harness = \"claude\""
! grep -qE '^context_window = ' "$tmp_claude" \
  || ac_fail "claude path must not write context_window"
rm -f "$tmp_dsh" "$tmp_claude"
ac_log "AC 2 OK: harness key always written, context_window only on dsh"

# ── 3. The harness bats suite passes ─────────────────────────────────────────
ac_log "AC 3: the harness suite"
ac_run_bats_suite "$HIRE_SUITE"
ac_assert_eq "$bats_rc" "0" \
  "hire suite must pass (rc=$bats_rc): $bats_out"
ac_log "AC 3 OK: suite green"

ac_pass
