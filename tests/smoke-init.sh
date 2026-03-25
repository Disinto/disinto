#!/usr/bin/env bash
# tests/smoke-init.sh — End-to-end smoke test for disinto init
#
# Expects a running Forgejo at SMOKE_FORGE_URL with a bootstrap admin
# user already created (see .woodpecker/smoke-init.yml for CI setup).
# Validates the full init flow: Forgejo API, user/token creation,
# repo setup, labels, TOML generation, and cron installation.
#
# Required env:  SMOKE_FORGE_URL (default: http://localhost:3000)
# Required tools: bash, curl, jq, python3, git

set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE_URL="${SMOKE_FORGE_URL:-http://localhost:3000}"
SETUP_ADMIN="setup-admin"
SETUP_PASS="SetupPass-789xyz"
TEST_SLUG="smoke-org/smoke-repo"
MOCK_BIN="/tmp/smoke-mock-bin"
MOCK_STATE="/tmp/smoke-mock-state"
FAILED=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

cleanup() {
  rm -rf "$MOCK_BIN" "$MOCK_STATE" /tmp/smoke-test-repo \
         "${FACTORY_ROOT}/projects/smoke-repo.toml" \
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
# Start with a clean .env (setup_forge writes tokens here)
printf '' > "${FACTORY_ROOT}/.env"

# ── 1. Verify Forgejo is ready ──────────────────────────────────────────────
echo "=== 1/6 Verifying Forgejo at ${FORGE_URL} ==="
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
    fail "Forgejo API not responding after 30s"
    exit 1
  fi
  sleep 1
done
pass "Forgejo API v${api_version} (${retries}s)"

# Verify bootstrap admin user exists
if curl -sf --max-time 5 "${FORGE_URL}/api/v1/users/${SETUP_ADMIN}" >/dev/null 2>&1; then
  pass "Bootstrap admin '${SETUP_ADMIN}' exists"
else
  fail "Bootstrap admin '${SETUP_ADMIN}' not found — was Forgejo set up?"
  exit 1
fi

# ── 2. Set up mock binaries ─────────────────────────────────────────────────
echo "=== 2/6 Setting up mock binaries ==="
mkdir -p "$MOCK_BIN" "$MOCK_STATE"

# Store bootstrap admin credentials for the docker mock
printf '%s:%s' "${SETUP_ADMIN}" "${SETUP_PASS}" > "$MOCK_STATE/bootstrap_creds"

# ── Mock: docker ──
# Routes 'docker exec' user-creation calls to the Forgejo admin API,
# using the bootstrap admin's credentials.
cat > "$MOCK_BIN/docker" << 'DOCKERMOCK'
#!/usr/bin/env bash
set -euo pipefail

FORGE_URL="${SMOKE_FORGE_URL:-http://localhost:3000}"
MOCK_STATE="/tmp/smoke-mock-state"

if [ ! -f "$MOCK_STATE/bootstrap_creds" ]; then
  echo "mock-docker: bootstrap credentials not found" >&2
  exit 1
fi
BOOTSTRAP_CREDS="$(cat "$MOCK_STATE/bootstrap_creds")"

# docker ps — return empty (no containers running)
if [ "${1:-}" = "ps" ]; then
  exit 0
fi

# docker exec — route to Forgejo API
if [ "${1:-}" = "exec" ]; then
  shift  # remove 'exec'

  # Skip docker exec flags (-u VALUE, -T, -i, etc.)
  while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do
    case "$1" in
      -u|-w|-e) shift 2 ;;
      *)        shift ;;
    esac
  done
  shift  # remove container name (e.g. disinto-forgejo)

  # $@ is now: forgejo admin user list|create [flags]
  if [ "${1:-}" = "forgejo" ] && [ "${2:-}" = "admin" ] && [ "${3:-}" = "user" ]; then
    subcmd="${4:-}"

    if [ "$subcmd" = "list" ]; then
      echo "ID   Username   Email"
      exit 0
    fi

    if [ "$subcmd" = "create" ]; then
      shift 4  # skip 'forgejo admin user create'
      username="" password="" email="" is_admin="false"
      while [ $# -gt 0 ]; do
        case "$1" in
          --admin)                is_admin="true"; shift ;;
          --username)             username="$2"; shift 2 ;;
          --password)             password="$2"; shift 2 ;;
          --email)                email="$2"; shift 2 ;;
          --must-change-password*) shift ;;
          *)                      shift ;;
        esac
      done

      if [ -z "$username" ] || [ -z "$password" ] || [ -z "$email" ]; then
        echo "mock-docker: missing required args" >&2
        exit 1
      fi

      # Create user via Forgejo admin API
      if ! curl -sf -X POST \
        -u "$BOOTSTRAP_CREDS" \
        -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/admin/users" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\",\"email\":\"${email}\",\"must_change_password\":false,\"login_name\":\"${username}\",\"source_id\":0}" \
        >/dev/null 2>&1; then
        echo "mock-docker: failed to create user '${username}'" >&2
        exit 1
      fi

      # Patch user: ensure must_change_password is false (Forgejo admin
      # API POST may ignore it) and promote to admin if requested
      patch_body="{\"must_change_password\":false,\"login_name\":\"${username}\",\"source_id\":0"
      if [ "$is_admin" = "true" ]; then
        patch_body="${patch_body},\"admin\":true"
      fi
      patch_body="${patch_body}}"

      curl -sf -X PATCH \
        -u "$BOOTSTRAP_CREDS" \
        -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/admin/users/${username}" \
        -d "${patch_body}" \
        >/dev/null 2>&1 || true

      echo "New user '${username}' has been successfully created!"
      exit 0
    fi
  fi

  echo "mock-docker: unhandled exec: $*" >&2
  exit 1
fi

echo "mock-docker: unhandled command: $*" >&2
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

# ── Mock: crontab ──
cat > "$MOCK_BIN/crontab" << 'CRONMOCK'
#!/usr/bin/env bash
CRON_FILE="/tmp/smoke-mock-state/crontab-entries"
case "${1:-}" in
  -l) cat "$CRON_FILE" 2>/dev/null || true ;;
  -)  cat > "$CRON_FILE" ;;
  *)  exit 0 ;;
esac
CRONMOCK
chmod +x "$MOCK_BIN/crontab"

export PATH="$MOCK_BIN:$PATH"
pass "Mock binaries installed (docker, claude, tmux, crontab)"

# ── 3. Run disinto init ─────────────────────────────────────────────────────
echo "=== 3/6 Running disinto init ==="
rm -f "${FACTORY_ROOT}/projects/smoke-repo.toml"

# Configure git identity (needed for git operations)
git config --global user.email "smoke@test.local"
git config --global user.name "Smoke Test"

export SMOKE_FORGE_URL="$FORGE_URL"
export FORGE_URL

if bash "${FACTORY_ROOT}/bin/disinto" init \
  "${TEST_SLUG}" \
  --bare --yes \
  --forge-url "$FORGE_URL" \
  --repo-root "/tmp/smoke-test-repo"; then
  pass "disinto init completed successfully"
else
  fail "disinto init exited non-zero"
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

# Labels exist on repo — use bootstrap admin to check
setup_token=$(curl -sf -X POST \
  -u "${SETUP_ADMIN}:${SETUP_PASS}" \
  -H "Content-Type: application/json" \
  "${FORGE_URL}/api/v1/users/${SETUP_ADMIN}/tokens" \
  -d '{"name":"smoke-verify","scopes":["all"]}' 2>/dev/null \
  | jq -r '.sha1 // empty') || setup_token=""

if [ -n "$setup_token" ]; then
  label_count=0
  for repo_path in "${TEST_SLUG}" "dev-bot/smoke-repo" "disinto-admin/smoke-repo"; do
    label_count=$(curl -sf \
      -H "Authorization: token ${setup_token}" \
      "${FORGE_URL}/api/v1/repos/${repo_path}/labels?limit=50" 2>/dev/null \
      | jq 'length' 2>/dev/null) || label_count=0
    if [ "$label_count" -gt 0 ]; then
      break
    fi
  done

  if [ "$label_count" -ge 5 ]; then
    pass "Labels created on repo (${label_count} labels)"
  else
    fail "Expected >= 5 labels, found ${label_count}"
  fi
else
  fail "Could not obtain verification token from bootstrap admin"
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

# Repo was cloned
if [ -d "/tmp/smoke-test-repo/.git" ]; then
  pass "Repo cloned to /tmp/smoke-test-repo"
else
  fail "Repo not cloned to /tmp/smoke-test-repo"
fi

# ── 6. Verify cron setup ────────────────────────────────────────────────────
echo "=== 6/6 Verifying cron setup ==="
cron_file="$MOCK_STATE/crontab-entries"
if [ -f "$cron_file" ]; then
  if grep -q 'dev-poll.sh' "$cron_file"; then
    pass "Cron includes dev-poll entry"
  else
    fail "Cron missing dev-poll entry"
  fi
  if grep -q 'review-poll.sh' "$cron_file"; then
    pass "Cron includes review-poll entry"
  else
    fail "Cron missing review-poll entry"
  fi
  if grep -q 'gardener-run.sh' "$cron_file"; then
    pass "Cron includes gardener entry"
  else
    fail "Cron missing gardener entry"
  fi
else
  fail "No cron entries captured (mock crontab file missing)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE-INIT TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE-INIT TEST PASSED ==="
