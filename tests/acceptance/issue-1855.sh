#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1855.sh
#
# Issue #1855: Claude-only setup output and wiring apply only to the claude
# harness.
#
#   1. CLAUDE_BIN_DIR is gone from lib/generators.sh and docker-compose.yml.
#   2. A local-model hire with --harness dsh writes no ANTHROPIC_BASE_URL=
#      line; --harness claude writes one. Forge calls are stubbed (no live
#      box), the same way tests/hire-an-agent-harness.bats stubs its CLIs.
#   3. print_init_claude_authentication (the block disinto init calls) prints
#      "Claude authentication" only when AGENT_HARNESS=claude. Full init still
#      belongs to tests/smoke-init.sh — this harness has no mock Forgejo.
#   4. The telemetry write disinto init runs is unconditional: executing those
#      lines against an empty .env leaves exactly one
#      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC line.
#
# Hermetic: no network, no forge, no Claude. Run via:
#   tools/run-acceptance.sh 1855
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash git jq grep python3

DISINTO="$REPO_ROOT/bin/disinto"
HIRE_LIB="$REPO_ROOT/lib/hire-agent.sh"
GENERATORS="$REPO_ROOT/lib/generators.sh"
COMPOSE="$REPO_ROOT/docker-compose.yml"

ac_assert_file "$DISINTO" "bin/disinto must exist"
ac_assert_file "$HIRE_LIB" "lib/hire-agent.sh must exist"
ac_assert_file "$GENERATORS" "lib/generators.sh must exist"
ac_assert_file "$COMPOSE" "docker-compose.yml must exist"

# ── 1. CLAUDE_BIN_DIR is gone from the two files that wired the host CLI ────
ac_log "AC 1: git grep CLAUDE_BIN_DIR in generators and compose is empty"
hits="$(git -C "$REPO_ROOT" grep -n CLAUDE_BIN_DIR -- lib/generators.sh docker-compose.yml || true)"
if [ -n "$hits" ]; then
  ac_fail "CLAUDE_BIN_DIR still present: ${hits}"
fi
ac_log "AC 1 OK"

# ── 2. Local-model hire writes ANTHROPIC_BASE_URL only for claude ───────────
ac_log "AC 2: hire --harness dsh writes no ANTHROPIC_BASE_URL; claude writes one"

HOST="$(mktemp -d "${TMPDIR:-/tmp}/issue-1855.XXXXXX")"
trap 'rm -rf "$HOST"' EXIT
mkdir -p "$HOST/bin"

# Forge stub. Every call succeeds so hire reaches Step 1.7 without a live
# box. Token endpoints return a sha1 jq can read; everything else returns a
# body with an id so a later repo-create check would also pass.
cat > "$HOST/bin/curl" << 'EOF'
#!/usr/bin/env bash
# Key on the whole argv: the URL is not always the last argument (POST
# puts -d after it). A token POST returns an object; a token list returns
# an array, matching the two jq expressions hire uses.
joined="$*"
post=0
case "$joined" in
  *-X\ POST*|*-XPOST*) post=1 ;;
esac
case "$joined" in
  */tokens|*/tokens/*|*/tokens\ *)
    if [ "$post" -eq 1 ]; then
      printf '%s\n' '{"sha1":"stubtoken"}'
    else
      printf '%s\n' '[{"sha1":"stubtoken"}]'
    fi
    ;;
  *)
    printf '%s\n' '{"id":1}'
    ;;
esac
exit 0
EOF
chmod +x "$HOST/bin/curl"

# Hire a local-model agent. Later steps (profile clone) may fail; Step 1.7
# has already written .env by then. FORGE_ADMIN_PAT is unset so the password
# path declares env_file (the PAT path never does).
hire_local() {
  local harness="$1"
  local root="$2"
  local rc=0
  mkdir -p "$root/formulas"
  printf '%s\n' 'name = "dev"' > "$root/formulas/dev.toml"
  : > "$root/.env"
  (
    export PATH="$HOST/bin:$PATH"
    export FACTORY_ROOT="$root"
    export FORGE_TOKEN="stub-token"
    export FORGE_URL="http://127.0.0.1:9"
    unset FORGE_ADMIN_PAT FORGE_REPO AGENT_HARNESS
    # shellcheck source=/dev/null
    source "$HIRE_LIB"
    disinto_hire_an_agent labbot dev \
      --local-model "http://10.0.0.1:8081" \
      --model qwen \
      --harness "$harness"
  ) >"$root/out" 2>"$root/err" || rc=$?
  printf '%s' "$rc" > "$root/rc"
}

hire_local dsh "$HOST/dsh"
if ! grep -qF 'Step 1.7:' "$HOST/dsh/out"; then
  ac_fail "dsh hire never reached Step 1.7 (rc=$(cat "$HOST/dsh/rc")); stderr=$(cat "$HOST/dsh/err"); stdout=$(cat "$HOST/dsh/out")"
fi
if grep -q '^ANTHROPIC_BASE_URL=' "$HOST/dsh/.env"; then
  ac_fail "dsh hire wrote ANTHROPIC_BASE_URL: $(cat "$HOST/dsh/.env")"
fi
grep -qF 'dsh harness: nothing to write (DSH_BASE_URL comes from [agents.<name>].base_url)' "$HOST/dsh/out" \
  || ac_fail "dsh hire did not print the nothing-to-write line: $(cat "$HOST/dsh/out")"

hire_local claude "$HOST/claude"
if ! grep -qF 'Step 1.7:' "$HOST/claude/out"; then
  ac_fail "claude hire never reached Step 1.7 (rc=$(cat "$HOST/claude/rc")); stderr=$(cat "$HOST/claude/err"); stdout=$(cat "$HOST/claude/out")"
fi
grep -qx 'ANTHROPIC_BASE_URL=http://10.0.0.1:8081' "$HOST/claude/.env" \
  || ac_fail "claude hire did not write ANTHROPIC_BASE_URL: $(cat "$HOST/claude/.env")"
ac_log "AC 2 OK"

# ── 3. Init summary mentions Claude authentication only for the claude harness
ac_log "AC 3: Claude authentication line is claude-harness only"
FN="$(ac_extract_fn print_init_claude_authentication "$DISINTO")"
[ -n "$FN" ] || ac_fail "could not extract print_init_claude_authentication"
grep -qF '[ "${AGENT_HARNESS:-}" = "claude" ]' <<<"$FN" \
  || ac_fail "auth summary must use the preflight_check harness check"

INIT_FN="$(ac_extract_fn disinto_init "$DISINTO")"
[ -n "$INIT_FN" ] || ac_fail "could not extract disinto_init"
grep -qF 'print_init_claude_authentication' <<<"$INIT_FN" \
  || ac_fail "disinto_init must call print_init_claude_authentication"
if grep -qF '── Claude authentication' <<<"$INIT_FN"; then
  ac_fail "disinto_init still prints the Claude authentication block itself"
fi

invoke_summary() {
  local mode="$1"
  local rc=0
  if [ "$mode" = "omit" ]; then
    env -u AGENT_HARNESS CLAUDE_CONFIG_DIR="/tmp/claude-config" FN_SRC="$FN" \
      bash -c 'eval "$FN_SRC"; print_init_claude_authentication' \
      >"$HOST/summary.out" 2>"$HOST/summary.err" || rc=$?
  else
    env AGENT_HARNESS="$mode" CLAUDE_CONFIG_DIR="/tmp/claude-config" FN_SRC="$FN" \
      bash -c 'eval "$FN_SRC"; print_init_claude_authentication' \
      >"$HOST/summary.out" 2>"$HOST/summary.err" || rc=$?
  fi
  printf '%s' "$rc"
}

rc="$(invoke_summary omit)"
ac_assert_eq "$rc" "0" "omitted AGENT_HARNESS summary must exit 0 (got ${rc})"
if grep -qF 'Claude authentication' "$HOST/summary.out"; then
  ac_fail "omitted AGENT_HARNESS printed Claude authentication: $(cat "$HOST/summary.out")"
fi

rc="$(invoke_summary dsh)"
ac_assert_eq "$rc" "0" "AGENT_HARNESS=dsh summary must exit 0 (got ${rc})"
if grep -qF 'Claude authentication' "$HOST/summary.out"; then
  ac_fail "AGENT_HARNESS=dsh printed Claude authentication: $(cat "$HOST/summary.out")"
fi

rc="$(invoke_summary claude)"
ac_assert_eq "$rc" "0" "AGENT_HARNESS=claude summary must exit 0 (got ${rc}); stderr=$(cat "$HOST/summary.err")"
grep -qF 'Claude authentication' "$HOST/summary.out" \
  || ac_fail "AGENT_HARNESS=claude did not print Claude authentication: $(cat "$HOST/summary.out")"
ac_log "AC 3 OK"

# ── 4. Telemetry disable line is still written, and not harness-gated ───────
ac_log "AC 4: init still writes exactly one CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC line"
grep -qF "printf 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1\\n'" <<<"$INIT_FN" \
  || ac_fail "disinto_init no longer writes CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
# The write sits in disinto_init, outside the claude-only helper.
if grep -qF 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' <<<"$FN"; then
  ac_fail "telemetry write must stay outside the claude-only auth summary"
fi

WRITE="$(awk '
  /Ensure Claude Code never auto-updates/ { capture = 1; next }
  capture && /^  if / { capture = 2 }
  capture == 2 { print }
  capture == 2 && /^  fi$/ { exit }
' "$DISINTO")"
[ -n "$WRITE" ] || ac_fail "could not extract the telemetry write block"
env_file="$HOST/init.env"
: > "$env_file"
# shellcheck disable=SC2086
eval "$WRITE"
traffic_count="$(grep -c '^CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' "$env_file" || true)"
ac_assert_eq "$traffic_count" "1" \
  "init telemetry write must leave exactly one line (got ${traffic_count}): $(cat "$env_file")"
# Idempotent: a second pass must not add another line.
eval "$WRITE"
traffic_count="$(grep -c '^CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' "$env_file" || true)"
ac_assert_eq "$traffic_count" "1" \
  "init telemetry write must stay at one line on re-run (got ${traffic_count})"
ac_log "AC 4 OK"

# ── 5. Scripts parse; compose file still parses ─────────────────────────────
ac_log "AC 5: bash -n and compose parse"
bash -n "$DISINTO" || ac_fail "bash -n bin/disinto failed"
bash -n "$GENERATORS" || ac_fail "bash -n lib/generators.sh failed"
bash -n "$HIRE_LIB" || ac_fail "bash -n lib/hire-agent.sh failed"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$COMPOSE" config -q \
    || ac_fail "docker compose config -q failed"
elif command -v yq >/dev/null 2>&1; then
  yq '.' "$COMPOSE" >/dev/null \
    || ac_fail "yq parse of docker-compose.yml failed"
else
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$COMPOSE" \
    || ac_fail "YAML parse of docker-compose.yml failed"
fi
ac_log "AC 5 OK"

ac_pass
