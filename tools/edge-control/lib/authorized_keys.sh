#!/usr/bin/env bash
# =============================================================================
# lib/authorized_keys.sh — Rebuild authorized_keys from the registry + ledger
#
# Rebuilds disinto-tunnel's authorized_keys from the port registry. For each
# registered project this looks up the account-ledger row that holds that
# project's name, and writes a single line ONLY when that row carries a
# valid (allowlisted) public key:
#
#     restrict,port-forwarding,permitlisten="127.0.0.1:PORT",command="/bin/false" PUBKEY
#
# Rules:
#   * The line's key is the ledger row's `pubkey` — never the registry entry's
#     copy (set by the old apply_approve flow) and never a fingerprint (a
#     SHA256: string is not a key and cannot authenticate).
#   * A project whose ledger row has no `pubkey`, or whose `pubkey` does not
#     match an allowlisted public-key shape (ssh-ed25519 / ssh-rsa /
#     ecdsa-sha2-nistp{256,384,521}) is skipped — never written as a
#     fingerprint.
#   * A project that is not in the registry is not written (even if its
#     ledger row carries a valid key).
#   * No other options: `restrict` + `port-forwarding`, `permitlisten` limited
#     to the registry port, and `command="/bin/false"` — no shell, no agent
#     forwarding, nothing else.
#
# The tunnel user (disinto-tunnel) is created by porter-install.sh — not here.
# This library never useradds; it only creates the directory for the file and
# writes the file itself.
#
# Functions:
#   generate_authorized_keys_content → prints the generated authorized_keys
#     content (one line per valid registered project; nothing when none).
#   rebuild_authorized_keys  → rebuilds TUNNEL_AUTH_KEYS from the registry +
#     the ledger (the entry point used by apply-name.sh).
#   get_tunnel_authorized_keys → prints the generated authorized_keys content
#     (existing file, if any, else the generated content).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/ports.sh"
# shellcheck disable=SC1090
source "${SCRIPT_DIR}/accounts.sh"

# The public-key shape that qualifies as a tunnel key: an allowlisted key type
# plus a base64 key body. A SHA256: fingerprint does not match and is never
# written — it cannot authenticate.
PUBKEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) [A-Za-z0-9+/=]+$'

# The tunnel account's authorized_keys path. PORTER_ROOT prefixes it when set
# and non-empty (acceptance tests); otherwise the real /home/... path. The
# tunnel user itself is not created here — that is porter-install.sh's job.
TUNNEL_USER="disinto-tunnel"
TUNNEL_SSH_DIR="/home/${TUNNEL_USER}/.ssh"
TUNNEL_AUTH_KEYS="${TUNNEL_SSH_DIR}/authorized_keys"
if [[ -n "${PORTER_ROOT:-}" ]]; then
  TUNNEL_AUTH_KEYS="${PORTER_ROOT%/}/home/${TUNNEL_USER}/.ssh/authorized_keys"
fi

# Emit the generated authorized_keys content: one line per registered project
# whose ledger row carries a valid pubkey. Always returns 0; prints nothing
# (an empty authorized_keys) when no registered project qualifies.
generate_authorized_keys_content() {
  local content=""
  local first=true

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    local project port
    project="$(printf '%s' "$line" | jq -r '.name // empty' 2>/dev/null || true)"
    port="$(printf '%s' "$line" | jq -r '.port // empty' 2>/dev/null || true)"

    # Missing required registry fields -> skip.
    if [[ -z "$project" || -z "$port" ]]; then
      continue
    fi

    # Find the ledger row that holds this project name. If there is no row for
    # it (or the ledger is unreadable), there is nothing to write -> skip.
    local fp
    fp="$(row_fp_by_name "$project" 2>/dev/null || true)"
    if [[ -z "$fp" ]]; then
      continue
    fi

    # Take the stored public key off that row (the registry's own copied field
    # is not trusted — it is the fingerprint from the old flow).
    local pubkey
    pubkey="$(jq -r --arg fp "$fp" \
      '(.accounts // {})[$fp].pubkey // empty' \
      "$ACCOUNTS_FILE" 2>/dev/null || true)"

    # Only a valid (allowlisted) public key qualifies; anything else — an
    # absent field or a fingerprint — is skipped, not written.
    if [[ -z "$pubkey" || ! "$pubkey" =~ $PUBKEY_RE ]]; then
      continue
    fi

    local auth_line
    auth_line="restrict,port-forwarding,permitlisten=\"127.0.0.1:${port}\",command=\"/bin/false\" ${pubkey}"
    if [ "$first" = true ]; then
      content="$auth_line"
      first=false
    else
      content="${content}
${auth_line}"
    fi
  done < <(list_ports)

  if [ -z "$content" ]; then
    # Nothing qualifies: empty authorized_keys (no placeholder comment).
    return 0
  fi
  printf '%s\n' "$content"
}

# Rebuild TUNNEL_AUTH_KEYS from the registry + ledger. Returns 0 on success.
# No useradd / user management — only the directory and the file.
rebuild_authorized_keys() {
  local content
  content="$(generate_authorized_keys_content)"

  # The directory must exist for the write; the user is porter-install.sh's job.
  mkdir -p "$(dirname "$TUNNEL_AUTH_KEYS")"
  printf '%s\n' "$content" > "$TUNNEL_AUTH_KEYS"
  chmod 600 "$TUNNEL_AUTH_KEYS"

  local entries
  entries="$(printf '%s\n' "$content" | grep -cF 'ssh-' 2>/dev/null || true)"
  echo "Rebuilt authorized_keys for ${TUNNEL_USER} (entries: ${entries:-0})" >&2
}

# Print the authorized_keys content (for verification).
get_tunnel_authorized_keys() {
  if [ -f "$TUNNEL_AUTH_KEYS" ]; then
    cat "$TUNNEL_AUTH_KEYS"
  else
    generate_authorized_keys_content
  fi
}
