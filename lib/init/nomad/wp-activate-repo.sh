#!/usr/bin/env bash
# =============================================================================
# lib/init/nomad/wp-activate-repo.sh — Activate project repo in Woodpecker
#
# Part of the Nomad+Vault migration (issue #570). After Woodpecker is healthy
# and wp-oauth-register.sh has registered the OAuth app, this script:
#
#   1. Inserts (or updates) the project repo row in Woodpecker's sqlite DB
#      with active=1, so the review-bot sees "success" states on PR commits.
#   2. Registers a Forgejo webhook pointing at WP's /api/hook endpoint, so
#      pushes + PR events fire Woodpecker pipelines automatically.
#
# Direct DB insert is used because Woodpecker's repo-activation API requires
# a WP session token that only exists after an interactive OAuth login. In a
# headless factory init we don't have one, so we seed the DB row ourselves.
#
# Preconditions:
#   - Woodpecker alloc healthy at WP_HOST (default: http://localhost:8000)
#   - Forgejo reachable at FORGE_URL
#   - FORGE_TOKEN present with admin scope
#   - Forgejo user `disinto-admin` exists in Woodpecker users table
#     (created on first OAuth login; wp-oauth-register.sh doesn't do this
#     on fresh boxes, so see the companion gap note in #570)
#
# Idempotency:
#   - Repo row: INSERT OR REPLACE on (owner, name, forge_id)
#   - Webhook: GET existing hooks first, skip if one already targets WP
#
# Requires: sqlite3 (on the WP alloc host) OR python3, curl, jq
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=../../../lib/env.sh
source "${REPO_ROOT}/lib/env.sh"

FORGE_URL="${FORGE_URL:-http://127.0.0.1:3000}"
FORGE_TOKEN="${FORGE_TOKEN:-}"
FORGE_REPO="${FORGE_REPO:-}"  # e.g. disinto-admin/disinto
WP_HOST="${WP_HOST:-http://127.0.0.1:8000}"
WOODPECKER_HOST="${WOODPECKER_HOST:-${WP_HOST}}"
WP_DB="${WP_DB:-/srv/disinto/woodpecker-data/woodpecker.sqlite}"
WP_HOOK_URL="${WP_HOOK_URL:-}"  # computed after DB step (needs JWT)

LOG_TAG="[wp-activate-repo]"
log() { printf '%s %s\n' "$LOG_TAG" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

[ -n "$FORGE_TOKEN" ] || die "FORGE_TOKEN required"
[ -n "$FORGE_REPO" ]  || die "FORGE_REPO required (e.g. disinto-admin/disinto)"
[ -f "$WP_DB" ]       || die "WP sqlite DB not found at $WP_DB"

FORGE_OWNER="${FORGE_REPO%/*}"

log "── Step 1/3: look up Forgejo repo metadata ──"
repo_json=$(curl -sf --max-time 10 \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/repos/${FORGE_REPO}") \
  || die "failed to read Forgejo repo ${FORGE_REPO}"

forge_remote_id=$(printf '%s' "$repo_json" | jq -r '.id // empty')
default_branch=$(printf '%s' "$repo_json" | jq -r '.default_branch // "main"')
clone_url=$(printf '%s' "$repo_json" | jq -r '.clone_url // empty')
ssh_url=$(printf '%s' "$repo_json" | jq -r '.ssh_url // empty')

[ -n "$forge_remote_id" ] || die "failed to parse Forgejo repo id"
log "Forgejo repo id=${forge_remote_id}, branch=${default_branch}"

log "── Step 2/3: activate repo row in Woodpecker DB ──"
HASH=$(openssl rand -hex 32)

python3 - "${WP_DB}" "${FORGE_OWNER}" "${FORGE_REPO}" "${forge_remote_id}" \
  "${clone_url}" "${ssh_url}" "${default_branch}" "${HASH}" "${FORGE_URL}" <<PY
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
# Find forge_id and admin user_id (seeded by OAuth flow).
forge_id = next((r[0] for r in c.execute("SELECT id FROM forges LIMIT 1")), None)
admin_uid = next((r[0] for r in c.execute("SELECT id FROM users WHERE admin=1 LIMIT 1")), None)
if forge_id is None or admin_uid is None:
    print("ERROR: forges/users not seeded — run wp-oauth-register.sh first", file=sys.stderr)
    sys.exit(1)
# Ensure org row
org_id = next((r[0] for r in c.execute(
    "SELECT id FROM orgs WHERE forge_id=? AND name=?", (forge_id, sys.argv[2]))), None)
if org_id is None:
    c.execute("INSERT INTO orgs (forge_id, name, is_user, private) VALUES (?,?,0,0)",
              (forge_id, sys.argv[2]))
    org_id = c.lastrowid
existing = next((r[0] for r in c.execute(
    "SELECT id FROM repos WHERE forge_id=? AND full_name=?",
    (forge_id, sys.argv[3]))), None)
if existing:
    c.execute("UPDATE repos SET active=1, allow_pr=1 WHERE id=?", (existing,))
    print(f"repo row id={existing} updated (active=1)")
else:
    c.execute(
        "INSERT INTO repos (user_id, forge_id, forge_remote_id, org_id, owner, name, full_name,"
        "  avatar, forge_url, clone, clone_ssh, branch, pr_enabled, timeout, visibility, private,"
        "  trusted, require_approval, approval_allowed_users, active, allow_pr, allow_deploy,"
        "  config_path, hash, cancel_previous_pipeline_events, netrc_trusted,"
        "  config_extension_endpoint, config_extension_exclusive, config_extension_netrc,"
        "  registry_extension_endpoint, registry_extension_netrc,"
        "  secret_extension_endpoint, secret_extension_netrc)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (admin_uid, forge_id, sys.argv[4], org_id, sys.argv[2], sys.argv[3].split("/")[-1],
         sys.argv[3], "", f"{sys.argv[8]}/{sys.argv[3]}", sys.argv[5], sys.argv[6],
         sys.argv[7], 1, 60, "public", 0, 0, '{"network":false,"security":false,"volumes":false}',
         "none", "[]",
         1, 1, 0, "[]", sys.argv[8], "[]", 0, "[]", 0, "[]", 0))
    print("repo row inserted")
c.commit()
PY

# Compute JWT: {"type":"hook","forge-id":"<int>","repo-forge-remote-id":"<int>"} signed with repos.hash
log "── Step 2b/3: compute JWT for webhook URL ──"
JWT=$(python3 - "${HASH}" "${forge_remote_id}" "${WOODPECKER_HOST}" <<PY
import sqlite3, sys, json, hmac, hashlib, base64

hash_val = sys.argv[1]
repo_remote_id = sys.argv[2]
wp_host = sys.argv[3]

c = sqlite3.connect("${WP_DB}")
forge_id = next((r[0] for r in c.execute("SELECT id FROM forges LIMIT 1")), None)
c.close()

def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = _b64url(json.dumps({
    "type": "hook",
    "forge-id": str(forge_id),
    "repo-forge-remote-id": str(repo_remote_id),
}, separators=(",", ":")).encode())
signing_input = f"{header}.{payload}"
sig = hmac.new(hash_val.encode(), signing_input.encode(), hashlib.sha256).digest()
token = f"{signing_input}.{_b64url(sig)}"

# Build URL: join wp_host (may include subpath) + /api/hook?access_token=jwt
url = wp_host.rstrip("/") + "/api/hook?access_token=" + token
print(url)
PY
)

log "── Step 3/3: register Forgejo webhook to Woodpecker ──"
hooks=$(curl -sf --max-time 10 \
  -H "Authorization: token ${FORGE_TOKEN}" \
  "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/hooks") || hooks="[]"

if printf '%s' "$hooks" | jq -e --arg url "$JWT" '.[] | select(.config.url == $url)' >/dev/null 2>&1; then
    log "webhook already exists — skip"
else
    if curl -sf --max-time 10 -X POST \
        -H "Authorization: token ${FORGE_TOKEN}" \
        -H "Content-Type: application/json" \
        "${FORGE_URL}/api/v1/repos/${FORGE_REPO}/hooks" \
        -d "$(jq -n --arg url "$JWT" '{
          type: "forgejo",
          config: { url: $url, content_type: "json" },
          events: ["push", "pull_request", "pull_request_sync"],
          active: true
        }')" >/dev/null; then
        log "webhook registered"
    else
        die "failed to register webhook"
    fi
fi

log "done — repo activated, webhook wired"
