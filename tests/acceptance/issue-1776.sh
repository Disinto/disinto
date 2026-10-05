#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1776.sh
#
# Issue #1776: the vault runner's .toml branch must run the formula through
# agent_run (dsh), never `claude -p`. An empty DSH_BASE_URL is a hard error.
#
# Acceptance (no network, no model):
#   1. docker/runner/entrypoint-runner.sh contains neither `claude -p` nor
#      `exec claude`.
#   2. With dsh and claude stubbed first on PATH, AGENT_HARNESS=claude, and
#      DSH_BASE_URL set, an action whose formula is run-publish-site exits 0:
#      dsh was called with --profile headless, claude was not called, and
#      $DSH_HOME/settings.yaml contains the base URL.
#   3. The same run with DSH_BASE_URL unset exits non-zero, and neither stub
#      was called.
#
# OPS_REPO_ROOT, HOME, DSH_HOME, NOMAD_SECRETS_DIR and DISINTO_LOG_DIR point
# into a temp dir. FORGE_PASS is unset, so the git-creds step does nothing.
#
# Run via: tools/run-acceptance.sh 1776
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep sed

ENTRYPOINT="$REPO_ROOT/docker/runner/entrypoint-runner.sh"
ac_assert_file "$ENTRYPOINT" "docker/runner/entrypoint-runner.sh must exist"
ac_assert_file "$REPO_ROOT/formulas/run-publish-site.toml" \
  "formulas/run-publish-site.toml must exist (the acceptance action's formula)"

# ── 1. No Claude invocation left in the runner ──────────────────────────────
ac_log "AC 1: entrypoint-runner.sh has no claude -p / exec claude"
claude_hits="$(grep -nE 'claude -p|exec claude' "$ENTRYPOINT" || true)"
[ -z "$claude_hits" ] \
  || ac_fail "entrypoint-runner.sh must not invoke claude (got: ${claude_hits})"
ac_log "AC 1 OK"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OPS_DIR="$TMP_DIR/ops"
HOME_DIR="$TMP_DIR/home"
DSH_DIR="$TMP_DIR/dsh-home"
SECRETS_DIR="$TMP_DIR/secrets"
LOG_DIR="$TMP_DIR/logs"
SEED_DIR="$TMP_DIR/seed"
BIN_DIR="$TMP_DIR/bin"
DSH_LOG="$TMP_DIR/dsh-args"
CLAUDE_LOG="$TMP_DIR/claude-args"
ACTION_ID="act-1776"

mkdir -p "$OPS_DIR/vault/actions" "$HOME_DIR" "$SECRETS_DIR" "$LOG_DIR" \
  "$SEED_DIR/profiles" "$BIN_DIR"

printf '%s\n' '{"name":"headless"}' > "$SEED_DIR/profiles/headless.json"
printf '%s\n' 'baseURL: __DSH_BASE_URL__' > "$SEED_DIR/settings-llamacpp.yaml"
printf '%s\n' 'formula = "run-publish-site"' 'context = "acceptance"' \
  > "$OPS_DIR/vault/actions/${ACTION_ID}.toml"

# Stubs record argv and exit 0. Absolute log paths are baked in so a child
# that unsets the environment still leaves proof of which binary ran.
cat > "$BIN_DIR/dsh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DSH_LOG"
exit 0
EOF
cat > "$BIN_DIR/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLAUDE_LOG"
exit 0
EOF
chmod +x "$BIN_DIR/dsh" "$BIN_DIR/claude"

# Shared env for both runs. FORGE_PASS is stripped so configure_git_creds
# returns immediately (it would otherwise wait on Forgejo). A missing
# argument unsets DSH_BASE_URL even if the parent exported it.
run_runner() {
  local -a cmd=(
    env -u FORGE_PASS -u DSH_BASE_URL
    "PATH=$BIN_DIR:$PATH"
    "OPS_REPO_ROOT=$OPS_DIR"
    "HOME=$HOME_DIR"
    "DSH_HOME=$DSH_DIR"
    "NOMAD_SECRETS_DIR=$SECRETS_DIR"
    "DISINTO_LOG_DIR=$LOG_DIR"
    "DSH_SEED_DIR=$SEED_DIR"
    "FACTORY_ROOT=$REPO_ROOT"
    "AGENT_HARNESS=claude"
  )
  if [ "$#" -gt 0 ]; then
    cmd+=("DSH_BASE_URL=$1")
  fi
  "${cmd[@]}" bash "$ENTRYPOINT" "$ACTION_ID"
}

# ── 2. AGENT_HARNESS=claude still goes through dsh ──────────────────────────
ac_log "AC 2: .toml formula runs via dsh --profile headless, not claude"
rm -f "$DSH_LOG" "$CLAUDE_LOG"
rc=0
out="$(run_runner "http://127.0.0.1:9/v1" 2>&1)" || rc=$?
ac_assert_eq "$rc" "0" \
  "entrypoint-runner.sh must exit 0 with DSH_BASE_URL set (rc=$rc): $out"
[ -f "$DSH_LOG" ] \
  || ac_fail "dsh stub was not called: $out"
grep -q -- '--profile headless' "$DSH_LOG" \
  || ac_fail "dsh stub was not called with --profile headless: $(cat "$DSH_LOG")"
if [ -e "$CLAUDE_LOG" ]; then
  ac_fail "claude stub was called despite AGENT_HARNESS=claude being overridden: $(cat "$CLAUDE_LOG")"
fi
grep -qF 'http://127.0.0.1:9/v1' "$DSH_DIR/settings.yaml" \
  || ac_fail "\$DSH_HOME/settings.yaml must contain the DSH_BASE_URL (got: $(cat "$DSH_DIR/settings.yaml" 2>/dev/null || echo missing))"
ac_log "AC 2 OK"

# ── 3. Missing DSH_BASE_URL is fatal and calls neither harness ──────────────
ac_log "AC 3: unset DSH_BASE_URL exits non-zero; neither stub is called"
rm -f "$DSH_LOG" "$CLAUDE_LOG"
rc=0
out="$(run_runner 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  || ac_fail "entrypoint-runner.sh must exit non-zero when DSH_BASE_URL is unset (output: $out)"
if [ -e "$DSH_LOG" ] || [ -e "$CLAUDE_LOG" ]; then
  ac_fail "a harness stub was called with DSH_BASE_URL unset (dsh=$(cat "$DSH_LOG" 2>/dev/null || echo none); claude=$(cat "$CLAUDE_LOG" 2>/dev/null || echo none))"
fi
printf '%s\n' "$out" | grep -qF 'DSH_BASE_URL not set' \
  || ac_fail "missing DSH_BASE_URL must log the runner error (got: $out)"
ac_log "AC 3 OK"

ac_pass
