#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1837.sh
#
# Issue #1837: sidecar_agent_run runs one sidecar session with dsh and the
# Playwright MCP overlay in docker/reproduce/dsh-playwright.patch.yml.
#
# Acceptance (no network, no model, no browser):
#   1. yq reads the patch plugin name and command.
#   2. A stub dsh on PATH: sidecar_agent_run returns 0, writes the stub's
#      answer, passes --profile headless --patch <repo>/docker/reproduce/dsh-playwright.patch.yml,
#      and seeds $DSH_HOME/settings.yaml with DSH_BASE_URL.
#   3. A stub that sleeps 5s with TIMEOUT_S=1 returns 124.
#   4. With DSH_BASE_URL unset, returns 1, does not call the stub, and the
#      output names DSH_BASE_URL not set.
#
# Run via: tools/run-acceptance.sh 1837
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash yq timeout grep

PATCH="$REPO_ROOT/docker/reproduce/dsh-playwright.patch.yml"
HELPER="$REPO_ROOT/docker/reproduce/sidecar-agent.sh"
ac_assert_file "$PATCH" "docker/reproduce/dsh-playwright.patch.yml must exist"
ac_assert_file "$HELPER" "docker/reproduce/sidecar-agent.sh must exist"

# ── 1. The overlay names the dsh MCP client and playwright-mcp ───────────────
ac_log "AC 1: yq reads the Playwright MCP plugin name and command"
name="$(yq '.[0].insert[0].name' "$PATCH")"
[ "$name" = "@deepseek-ai/dsh-mcp-client" ] \
  || ac_fail "patch plugin name must be @deepseek-ai/dsh-mcp-client (got: ${name})"
command="$(yq '.[0].insert[0].config.command' "$PATCH")"
[ "$command" = "playwright-mcp" ] \
  || ac_fail "patch command must be playwright-mcp (got: ${command})"
ac_log "AC 1 OK"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SEED_DIR="$TMP_DIR/seed"
mkdir -p "$SEED_DIR/profiles"
printf '%s\n' '{"name":"headless"}' > "$SEED_DIR/profiles/headless.json"
printf '%s\n' 'baseURL: __DSH_BASE_URL__' > "$SEED_DIR/settings-llamacpp.yaml"

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"
# Stub dsh: logs argv (one argument per line) and either prints the final
# answer or sleeps. DSH_STUB_SLEEP=1 selects the timeout case.
cat > "$BIN_DIR/dsh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${DSH_ARGV_LOG:?}"
if [ "${DSH_STUB_SLEEP:-}" = "1" ]; then
  sleep 5
fi
printf 'final answer\n'
EOF
chmod +x "$BIN_DIR/dsh"

# Fresh DSH_HOME: dsh_seed_home (lib/dsh-seed.sh) will not overwrite an
# existing settings.yaml, so the default /tmp/dsh-sidecar must not leak in.
export PATH="${BIN_DIR}:${PATH}"
export DISINTO_DIR="$REPO_ROOT"
export DSH_SEED_DIR="$SEED_DIR"
export DSH_BASE_URL="http://127.0.0.1:9/v1"
export DSH_HOME="$TMP_DIR/dsh-home"
export LOGFILE="$TMP_DIR/sidecar.log"
export DSH_ARGV_LOG="$TMP_DIR/argv.log"
: > "$LOGFILE"
: > "$DSH_ARGV_LOG"
unset DSH_STUB_SLEEP

# shellcheck source=docker/reproduce/sidecar-agent.sh
source "$HELPER"

# run_sidecar PROMPT OUT TIMEOUT — prints the function's exit code.
run_sidecar() {
  local rc=0
  sidecar_agent_run "$1" "$2" "$3" || rc=$?
  printf '%s\n' "$rc"
}

# ── 2. One headless dsh run, answer captured, home seeded ────────────────────
ac_log "AC 2: stub dsh returns 0, captures the answer, and seeds settings.yaml"
OUT="$TMP_DIR/out.txt"
rc="$(run_sidecar hi "$OUT" 30)"
[ "$rc" = "0" ] \
  || ac_fail "sidecar_agent_run must return 0 (rc=$rc, log: $(cat "$LOGFILE"))"
grep -qF 'final answer' "$OUT" \
  || ac_fail "output must contain the stub's final answer (got: $(cat "$OUT"))"
mapfile -t argv < "$DSH_ARGV_LOG"
[ "${#argv[@]}" -ge 4 ] \
  || ac_fail "stub argv must include the profile and patch flags (got: ${argv[*]:-nothing})"
[ "${argv[0]}" = "--profile" ] && [ "${argv[1]}" = "headless" ] \
  && [ "${argv[2]}" = "--patch" ] \
  && [ "${argv[3]}" = "${REPO_ROOT}/docker/reproduce/dsh-playwright.patch.yml" ] \
  || ac_fail "stub argv must start --profile headless --patch ${REPO_ROOT}/docker/reproduce/dsh-playwright.patch.yml (got: ${argv[*]})"
[ -f "$DSH_HOME/settings.yaml" ] \
  || ac_fail "dsh_seed_home must write \$DSH_HOME/settings.yaml"
grep -qF 'http://127.0.0.1:9/v1' "$DSH_HOME/settings.yaml" \
  || ac_fail "settings.yaml must contain DSH_BASE_URL (got: $(cat "$DSH_HOME/settings.yaml"))"
ac_log "AC 2 OK"

# ── 3. Wall-clock timeout is 124 ─────────────────────────────────────────────
ac_log "AC 3: a 5s stub with TIMEOUT_S=1 returns 124"
export DSH_STUB_SLEEP=1
: > "$DSH_ARGV_LOG"
OUT_TIMEOUT="$TMP_DIR/out-timeout.txt"
rc="$(run_sidecar hi "$OUT_TIMEOUT" 1)"
[ "$rc" = "124" ] \
  || ac_fail "sidecar_agent_run must return 124 when TIMEOUT_S is reached (rc=$rc)"
ac_log "AC 3 OK"

# ── 4. No URL, no session ────────────────────────────────────────────────────
ac_log "AC 4: unset DSH_BASE_URL returns 1 without calling dsh"
unset DSH_BASE_URL
unset DSH_STUB_SLEEP
: > "$DSH_ARGV_LOG"
OUT_NOURL="$TMP_DIR/out-nourl.txt"
rc="$(run_sidecar hi "$OUT_NOURL" 30)"
[ "$rc" = "1" ] \
  || ac_fail "sidecar_agent_run must return 1 when DSH_BASE_URL is unset (rc=$rc)"
[ ! -s "$DSH_ARGV_LOG" ] \
  || ac_fail "the stub must not be called when DSH_BASE_URL is unset (argv: $(cat "$DSH_ARGV_LOG"))"
grep -qF 'DSH_BASE_URL not set' "$OUT_NOURL" \
  || ac_fail "output must say DSH_BASE_URL not set (got: $(cat "$OUT_NOURL"))"
ac_log "AC 4 OK"

ac_pass
