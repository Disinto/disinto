#!/usr/bin/env bash
# tests/smoke-init.sh — End-to-end smoke test for disinto init with mock Forgejo
#
# Validates the full init flow using mock Forgejo server:
#   1. Verify mock Forgejo is ready
#   2. Set up mock binaries (docker, claude, tmux)
#   3. Run disinto init
#   4. Verify Forgejo state (users, repo)
#   5. Verify local state (TOML, .env, repo clone)
#   6. Verify scheduling setup
#
# Required env: FORGE_URL (default: http://localhost:3000)
# Required tools: bash, curl, jq, python3, git

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FACTORY_ROOT_REAL="$FACTORY_ROOT"
# Always use localhost for mock Forgejo (in case FORGE_URL is set from docker-compose)
export FORGE_URL="http://localhost:3000"
MOCK_BIN="/tmp/smoke-mock-bin"
TEST_SLUG="smoke-org/smoke-repo"
FAILED=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() {
  # Kill any leftover mock-forgejo.py processes by name
  pkill -f "mock-forgejo.py" 2>/dev/null || true
  rm -rf "$MOCK_BIN" /tmp/smoke-test-repo \
         "${FACTORY_ROOT}/projects/smoke-repo.toml" \
         /tmp/smoke-claude-shared /tmp/smoke-home-claude \
         /tmp/smoke-env-before-rerun /tmp/smoke-env-before-dryrun \
         "${FACTORY_ROOT}/docker-compose.yml"
  # Restore .env only if we created the backup
  if [ -f "${FACTORY_ROOT}/.env.smoke-backup" ]; then
    mv "${FACTORY_ROOT}/.env.smoke-backup" "${FACTORY_ROOT}/.env"
  else
    rm -f "${FACTORY_ROOT}/.env"
  fi
}
trap cleanup EXIT

# Back up existing .env if present
if [ -f "${FACTORY_ROOT}/.env" ]; then
  cp "${FACTORY_ROOT}/.env" "${FACTORY_ROOT}/.env.smoke-backup"
fi
# Start with a clean .env
printf '' > "${FACTORY_ROOT}/.env"

# ── 1. Verify mock Forgejo is ready ─────────────────────────────────────────
echo "=== 1/6 Verifying mock Forgejo at ${FORGE_URL} ==="
retries=0
api_version=""
while true; do
  api_version=$(curl -sf --max-time 3 "${FORGE_URL}/api/v1/version" 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null) || api_version=""
  if [ -n "$api_version" ]; then
    break
  fi
  retries=$((retries + 1))
  if [ "$retries" -gt 30 ]; then
    fail "Mock Forgejo API not responding after 30s"
    exit 1
  fi
  sleep 1
done
pass "Mock Forgejo API v${api_version} (${retries}s)"

# ── 2. Set up mock binaries ─────────────────────────────────────────────────
echo "=== 2/6 Setting up mock binaries ==="
mkdir -p "$MOCK_BIN"

# ── Mock: docker ──
# Intercepts docker exec calls that disinto init --bare makes to Forgejo CLI
cat > "$MOCK_BIN/docker" << 'DOCKERMOCK'
#!/usr/bin/env bash
set -euo pipefail
FORGE_URL="${SMOKE_FORGE_URL:-${FORGE_URL:-http://localhost:3000}}"
if [ "${1:-}" = "ps" ]; then exit 0; fi
if [ "${1:-}" = "exec" ]; then
  shift
  while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do
    case "$1" in -u|-w|-e) shift 2 ;; *) shift ;; esac
  done
  shift  # container name
  if [ "${1:-}" = "forgejo" ] && [ "${2:-}" = "admin" ] && [ "${3:-}" = "user" ]; then
    subcmd="${4:-}"
    if [ "$subcmd" = "list" ]; then echo "ID   Username   Email"; exit 0; fi
    if [ "$subcmd" = "create" ]; then
      shift 4; username="" password="" email="" is_admin="false"
      while [ $# -gt 0 ]; do
        case "$1" in
          --admin) is_admin="true"; shift ;; --username) username="$2"; shift 2 ;;
          --password) password="$2"; shift 2 ;; --email) email="$2"; shift 2 ;;
          --must-change-password*) shift ;; *) shift ;;
        esac
      done
      curl -sf -X POST -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/admin/users" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\",\"email\":\"${email}\",\"must_change_password\":false}" >/dev/null 2>&1
      if [ "$is_admin" = "true" ]; then
        curl -sf -X PATCH -H "Content-Type: application/json" \
          "${FORGE_URL}/api/v1/admin/users/${username}" \
          -d "{\"admin\":true,\"must_change_password\":false}" >/dev/null 2>&1 || true
      fi
      echo "New user '${username}' has been successfully created!"; exit 0
    fi
    if [ "$subcmd" = "change-password" ]; then
      shift 4; username=""
      while [ $# -gt 0 ]; do
        case "$1" in --username) username="$2"; shift 2 ;; --password) shift 2 ;; --must-change-password*|--config*) shift ;; *) shift ;; esac
      done
      curl -sf -X PATCH -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/admin/users/${username}" \
        -d "{\"must_change_password\":false}" >/dev/null 2>&1 || true
      exit 0
    fi
  fi
fi
exit 1
DOCKERMOCK
chmod +x "$MOCK_BIN/docker"

# ── Mock: claude ──
cat > "$MOCK_BIN/claude" << 'CLAUDEMOCK'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf '{"loggedIn":true}\n' ;;
  *"--version"*)   printf 'claude 1.0.0 (mock)\n' ;;
esac
exit 0
CLAUDEMOCK
chmod +x "$MOCK_BIN/claude"

# ── Mock: tmux ──
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_BIN/tmux"
chmod +x "$MOCK_BIN/tmux"

export PATH="$MOCK_BIN:$PATH"
pass "Mock binaries installed"

# ── 3. Run disinto init ─────────────────────────────────────────────────────
echo "=== 3/6 Running disinto init ==="
rm -f "${FACTORY_ROOT}/projects/smoke-repo.toml"

# Configure git identity (needed for git operations)
git config --global user.email "smoke@test.local"
git config --global user.name "Smoke Test"

# USER needs to be set twice: assignment then export (SC2155)
USER=$(whoami)
export USER

# Create mock git repo to avoid clone failure (mock server has no git support)
mkdir -p "/tmp/smoke-test-repo"
cd "/tmp/smoke-test-repo"
git init --quiet
git config user.email "smoke@test.local"
git config user.name "Smoke Test"
echo "# smoke-repo" > README.md
git add README.md
git commit --quiet -m "Initial commit"

export SMOKE_FORGE_URL="$FORGE_URL"
export FORGE_URL
# Required for non-interactive init (issue #620)
export FORGE_ADMIN_PASS="smoke-test-password-123"

# Skip push to mock server (no git support)
export SKIP_PUSH=true

if bash "${FACTORY_ROOT}/bin/disinto" init \
  "${TEST_SLUG}" \
  --bare --yes \
  --forge-url "$FORGE_URL" \
  --repo-root "/tmp/smoke-test-repo"; then
  pass "disinto init completed successfully"
else
  fail "disinto init exited non-zero"
fi

# ── Dry-run test: must not modify state ────────────────────────────────────
echo "=== Dry-run test ==="
cp "${FACTORY_ROOT}/.env" /tmp/smoke-env-before-dryrun
if bash "${FACTORY_ROOT}/bin/disinto" init \
  "${TEST_SLUG}" \
  --bare --yes --dry-run \
  --forge-url "$FORGE_URL" \
  --repo-root "/tmp/smoke-test-repo" 2>&1 | grep -q "Dry run complete"; then
  pass "disinto init --dry-run exited successfully"
else
  fail "disinto init --dry-run did not complete"
fi

# Verify --dry-run did not modify .env
if diff -q /tmp/smoke-env-before-dryrun "${FACTORY_ROOT}/.env" >/dev/null 2>&1; then
  pass "dry-run: .env unchanged"
else
  fail "dry-run: .env was modified (should be read-only)"
fi
rm -f /tmp/smoke-env-before-dryrun

# ── Idempotency test: run init again, verify .env is stable ────────────────
echo "=== Idempotency test: running disinto init again ==="
cp "${FACTORY_ROOT}/.env" /tmp/smoke-env-before-rerun
if bash "${FACTORY_ROOT}/bin/disinto" init \
  "${TEST_SLUG}" \
  --bare --yes \
  --forge-url "$FORGE_URL" \
  --repo-root "/tmp/smoke-test-repo"; then
  pass "disinto init (re-run) completed successfully"
else
  fail "disinto init (re-run) exited non-zero"
fi

# Verify .env is stable across re-runs (no token churn)
if diff -q /tmp/smoke-env-before-rerun "${FACTORY_ROOT}/.env" >/dev/null 2>&1; then
  pass "idempotency: .env unchanged on re-run"
else
  fail "idempotency: .env changed on re-run (token churn detected)"
  diff /tmp/smoke-env-before-rerun "${FACTORY_ROOT}/.env" >&2 || true
fi
rm -f /tmp/smoke-env-before-rerun

# Verify FORGE_ADMIN_TOKEN is stored in .env
if grep -q '^FORGE_ADMIN_TOKEN=' "${FACTORY_ROOT}/.env"; then
  pass ".env contains FORGE_ADMIN_TOKEN"
else
  fail ".env missing FORGE_ADMIN_TOKEN"
fi

# Verify HUMAN_TOKEN is stored in .env
if grep -q '^HUMAN_TOKEN=' "${FACTORY_ROOT}/.env"; then
  pass ".env contains HUMAN_TOKEN"
else
  fail ".env missing HUMAN_TOKEN"
fi

# ── 4. Verify Forgejo state ─────────────────────────────────────────────────
echo "=== 4/6 Verifying Forgejo state ==="

# Admin user exists
if curl -sf --max-time 5 "${FORGE_URL}/api/v1/users/disinto-admin" >/dev/null 2>&1; then
  pass "Admin user 'disinto-admin' exists on Forgejo"
else
  fail "Admin user 'disinto-admin' not found on Forgejo"
fi

# Bot users exist
for bot in dev-bot review-bot; do
  if curl -sf --max-time 5 "${FORGE_URL}/api/v1/users/${bot}" >/dev/null 2>&1; then
    pass "Bot user '${bot}' exists on Forgejo"
  else
    fail "Bot user '${bot}' not found on Forgejo"
  fi
done

# Repo exists (try org path, then fallback paths)
repo_found=false
for repo_path in "${TEST_SLUG}" "dev-bot/smoke-repo" "disinto-admin/smoke-repo"; do
  if curl -sf --max-time 5 "${FORGE_URL}/api/v1/repos/${repo_path}" >/dev/null 2>&1; then
    pass "Repo '${repo_path}' exists on Forgejo"
    repo_found=true
    break
  fi
done
if [ "$repo_found" = false ]; then
  fail "Repo not found on Forgejo under any expected path"
fi

# ── 5. Verify local state ───────────────────────────────────────────────────
echo "=== 5/6 Verifying local state ==="

# TOML was generated
toml_path="${FACTORY_ROOT}/projects/smoke-repo.toml"
if [ -f "$toml_path" ]; then
  toml_name=$(python3 -c "
import tomllib, sys
with open(sys.argv[1], 'rb') as f:
    print(tomllib.load(f)['name'])
" "$toml_path" 2>/dev/null) || toml_name=""

  if [ "$toml_name" = "smoke-repo" ]; then
    pass "TOML generated with correct project name"
  else
    fail "TOML name mismatch: expected 'smoke-repo', got '${toml_name}'"
  fi
else
  fail "TOML not generated at ${toml_path}"
fi

# .env has tokens
env_file="${FACTORY_ROOT}/.env"
if [ -f "$env_file" ]; then
  if grep -q '^FORGE_TOKEN=' "$env_file"; then
    pass ".env contains FORGE_TOKEN"
  else
    fail ".env missing FORGE_TOKEN"
  fi
  if grep -q '^FORGE_REVIEW_TOKEN=' "$env_file"; then
    pass ".env contains FORGE_REVIEW_TOKEN"
  else
    fail ".env missing FORGE_REVIEW_TOKEN"
  fi
else
  fail ".env not found"
fi

# Repo was cloned (mock git repo created before disinto init)
if [ -d "/tmp/smoke-test-repo/.git" ]; then
  pass "Repo cloned to /tmp/smoke-test-repo"
else
  fail "Repo not cloned to /tmp/smoke-test-repo"
fi

# ── 6. Verify scheduling setup ──────────────────────────────────────────────
echo "=== 6/6 Verifying scheduling setup ==="
# In compose mode, scheduling is handled by the entrypoint.sh polling loop.
# In bare-metal mode (--bare), crontab entries are installed.
# The smoke test runs without --bare, so cron install is skipped.
if [ -f "${FACTORY_ROOT:-}/docker-compose.yml" ] 2>/dev/null || true; then
  pass "Compose mode: scheduling handled by entrypoint.sh polling loop"
else
  cron_output=$(crontab -l 2>/dev/null) || cron_output=""
  if [ -n "$cron_output" ]; then
    if printf '%s' "$cron_output" | grep -q 'dev-poll.sh'; then
      pass "Bare-metal: crontab includes dev-poll entry"
    else
      fail "Bare-metal: crontab missing dev-poll entry"
    fi
  else
    pass "No crontab entries (expected in non-bare mode)"
  fi
fi

# ── 7. Verify CLAUDE_CONFIG_DIR setup ─────────────────────────────────────
echo "=== 7/7 Verifying CLAUDE_CONFIG_DIR setup ==="

# .env should contain CLAUDE_SHARED_DIR and CLAUDE_CONFIG_DIR
if grep -q '^CLAUDE_SHARED_DIR=' "$env_file"; then
  pass ".env contains CLAUDE_SHARED_DIR"
else
  fail ".env missing CLAUDE_SHARED_DIR"
fi
if grep -q '^CLAUDE_CONFIG_DIR=' "$env_file"; then
  pass ".env contains CLAUDE_CONFIG_DIR"
else
  fail ".env missing CLAUDE_CONFIG_DIR"
fi

# Test migration path with a temporary HOME
echo "--- Testing claude config migration ---"
ORIG_HOME="$HOME"
ORIG_CLAUDE_SHARED_DIR="${CLAUDE_SHARED_DIR:-}"
ORIG_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}"

export HOME="/tmp/smoke-home-claude"
export CLAUDE_SHARED_DIR="/tmp/smoke-claude-shared"
export CLAUDE_CONFIG_DIR="${CLAUDE_SHARED_DIR}/config"
mkdir -p "$HOME"

# Source claude-config.sh for setup_claude_config_dir
source "${FACTORY_ROOT}/lib/claude-config.sh"

# Sub-test 1: fresh install (no ~/.claude, no config dir)
rm -rf "$HOME/.claude" "$CLAUDE_SHARED_DIR"
setup_claude_config_dir "true"
if [ -d "$CLAUDE_CONFIG_DIR" ]; then
  pass "Fresh install: CLAUDE_CONFIG_DIR created"
else
  fail "Fresh install: CLAUDE_CONFIG_DIR not created"
fi
if [ -L "$HOME/.claude" ]; then
  pass "Fresh install: ~/.claude symlink created"
else
  fail "Fresh install: ~/.claude symlink not created"
fi

# Sub-test 2: migration (pre-existing ~/.claude with content)
rm -rf "$HOME/.claude" "$CLAUDE_SHARED_DIR"
mkdir -p "$HOME/.claude"
echo "test-token" > "$HOME/.claude/.credentials.json"
setup_claude_config_dir "true"
if [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
  pass "Migration: .credentials.json moved to CLAUDE_CONFIG_DIR"
else
  fail "Migration: .credentials.json not found in CLAUDE_CONFIG_DIR"
fi
if [ -L "$HOME/.claude" ]; then
  link_target=$(readlink -f "$HOME/.claude")
  config_real=$(readlink -f "$CLAUDE_CONFIG_DIR")
  if [ "$link_target" = "$config_real" ]; then
    pass "Migration: ~/.claude is symlink to CLAUDE_CONFIG_DIR"
  else
    fail "Migration: ~/.claude symlink points to wrong target"
  fi
else
  fail "Migration: ~/.claude is not a symlink"
fi

# Sub-test 3: idempotency (re-run after migration)
setup_claude_config_dir "true"
if [ -L "$HOME/.claude" ] && [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
  pass "Idempotency: re-run is a no-op"
else
  fail "Idempotency: re-run broke the layout"
fi

# Sub-test 4: both non-empty — must abort
rm -rf "$HOME/.claude" "$CLAUDE_SHARED_DIR"
mkdir -p "$HOME/.claude" "$CLAUDE_CONFIG_DIR"
echo "home-data" > "$HOME/.claude/home.txt"
echo "config-data" > "$CLAUDE_CONFIG_DIR/config.txt"
if setup_claude_config_dir "true" 2>/dev/null; then
  fail "Both non-empty: should have aborted but didn't"
else
  pass "Both non-empty: correctly aborted"
fi

# Restore
export HOME="$ORIG_HOME"
export CLAUDE_SHARED_DIR="$ORIG_CLAUDE_SHARED_DIR"
export CLAUDE_CONFIG_DIR="$ORIG_CLAUDE_CONFIG_DIR"
rm -rf /tmp/smoke-claude-shared /tmp/smoke-home-claude

# ── 8. Test duplicate service name detection ──────────────────────────────
echo "=== 8/8 Testing duplicate service name detection ==="

# Isolated factory root — do NOT touch the real ${FACTORY_ROOT}/projects/
SMOKE_DUP_ROOT=$(mktemp -d)
mkdir -p "$SMOKE_DUP_ROOT/projects"
cat > "$SMOKE_DUP_ROOT/projects/duplicate-test.toml" <<'TOMLEOF'
name = "duplicate-test"
description = "dup-detection smoke"

[ci]
woodpecker_repo_id = "999"

[agents.llama]
base_url = "http://localhost:8080"
model = "qwen:latest"
roles = ["dev"]
forge_user = "llama-bot"
TOMLEOF

# Call the generator directly — no `disinto init` to overwrite the TOML.
# FACTORY_ROOT tells generators.sh where projects/ + compose_file live.
(
  export FACTORY_ROOT="$SMOKE_DUP_ROOT"
  export ENABLE_LLAMA_AGENT=1
  # shellcheck disable=SC1091
  source "${FACTORY_ROOT_REAL:-$(cd "$(dirname "$0")/.." && pwd)}/lib/generators.sh"
  # Use a temp file to capture output since pipefail will kill the pipeline
  # when _generate_compose_impl returns non-zero
  _generate_compose_impl > /tmp/smoke-dup-output.txt 2>&1 || true
  if grep -q "Duplicate service name" /tmp/smoke-dup-output.txt; then
    pass "Duplicate service detection: conflict between ENABLE_LLAMA_AGENT and [agents.llama] reported"
    rm -f /tmp/smoke-dup-output.txt
    exit 0
  else
    fail "Duplicate service detection: no error raised for ENABLE_LLAMA_AGENT + [agents.llama]"
    cat /tmp/smoke-dup-output.txt >&2
    rm -f /tmp/smoke-dup-output.txt
    exit 1
  fi
) || FAILED=1

rm -rf "$SMOKE_DUP_ROOT"
unset ENABLE_LLAMA_AGENT

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE-INIT TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE-INIT TEST PASSED ==="
