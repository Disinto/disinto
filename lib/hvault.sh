#!/usr/bin/env bash
# hvault.sh — HashiCorp Vault helper module
#
# Typed, audited helpers for Vault KV v2 access so no script re-implements
# `curl -H "X-Vault-Token: ..."` ad-hoc.
#
# Usage: source this file, then call any hvault_* function.
#
# Environment:
#   VAULT_ADDR  — Vault server address (required, no default)
#   VAULT_TOKEN — auth token (precedence: env > /etc/vault.d/root.token)
#
# All functions emit structured JSON errors to stderr on failure.

set -euo pipefail

# ── Internal helpers ─────────────────────────────────────────────────────────

# _hvault_err — emit structured JSON error to stderr
# Args: func_name, message, [detail]
_hvault_err() {
  local func="$1" msg="$2" detail="${3:-}"
  jq -n --arg func "$func" --arg msg "$msg" --arg detail "$detail" \
    '{error:true,function:$func,message:$msg,detail:$detail}' >&2
}

# _hvault_resolve_token — resolve VAULT_TOKEN from env or token file
_hvault_resolve_token() {
  if [ -n "${VAULT_TOKEN:-}" ]; then
    return 0
  fi
  local token_file="/etc/vault.d/root.token"
  if [ -f "$token_file" ]; then
    VAULT_TOKEN="$(cat "$token_file")"
    export VAULT_TOKEN
    return 0
  fi
  return 1
}

# _hvault_default_env — set the local-cluster Vault env if unset
#
# Idempotent helper used by every Vault-touching script that runs during
# `disinto init` (S2). On the local-cluster common case, operators (and
# the init dispatcher in bin/disinto) have not exported VAULT_ADDR or
# VAULT_TOKEN — the server is reachable on localhost:8200 and the root
# token lives at /etc/vault.d/root.token. Scripts must Just Work in that
# shape.
#
#   - If VAULT_ADDR is unset, defaults to http://127.0.0.1:8200.
#   - If VAULT_TOKEN is unset, resolves from /etc/vault.d/root.token via
#     _hvault_resolve_token. A missing token file is not an error here —
#     downstream hvault_token_lookup() probes connectivity and emits the
#     operator-facing "VAULT_ADDR + VAULT_TOKEN" diagnostic.
#
# Centralised to keep the defaulting stanza in one place — copy-pasting
# the 5-line block into each init script trips the repo-wide 5-line
# sliding-window duplicate detector (.woodpecker/detect-duplicates.py).
_hvault_default_env() {
  VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
  export VAULT_ADDR
  _hvault_resolve_token || :
}

# _hvault_check_prereqs — validate VAULT_ADDR and VAULT_TOKEN are set
# Args: caller function name
_hvault_check_prereqs() {
  local caller="$1"
  if [ -z "${VAULT_ADDR:-}" ]; then
    _hvault_err "$caller" "VAULT_ADDR is not set" "export VAULT_ADDR before calling $caller"
    return 1
  fi
  if ! _hvault_resolve_token; then
    _hvault_err "$caller" "VAULT_TOKEN is not set and /etc/vault.d/root.token not found" \
      "export VAULT_TOKEN or write token to /etc/vault.d/root.token"
    return 1
  fi
}

# _hvault_request — execute a Vault API request
# Args: method, path, [data]
# Outputs: response body to stdout
# Returns: 0 on 2xx, 1 otherwise (error JSON to stderr)
_hvault_request() {
  local method="$1" path="$2" data="${3:-}"
  local url="${VAULT_ADDR}/v1/${path}"
  local http_code body
  local tmpfile
  tmpfile="$(mktemp)"

  local curl_args=(
    -s
    -w '%{http_code}'
    -H "X-Vault-Token: ${VAULT_TOKEN}"
    -H "Content-Type: application/json"
    -X "$method"
    -o "$tmpfile"
  )
  if [ -n "$data" ]; then
    curl_args+=(-d "$data")
  fi

  http_code="$(curl "${curl_args[@]}" "$url")" || {
    _hvault_err "_hvault_request" "curl failed" "url=$url"
    rm -f "$tmpfile"
    return 1
  }

  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  # Check HTTP status — 2xx is success
  case "$http_code" in
    2[0-9][0-9])
      printf '%s' "$body"
      return 0
      ;;
    *)
      _hvault_err "_hvault_request" "HTTP $http_code" "$body"
      return 1
      ;;
  esac
}

# ── Public API ───────────────────────────────────────────────────────────────

# VAULT_KV_MOUNT — KV v2 mount point (default: "kv")
#   Override with: export VAULT_KV_MOUNT=secret
#   Used by: hvault_kv_get, hvault_kv_put, hvault_kv_list
: "${VAULT_KV_MOUNT:=kv}"

# hvault_ensure_kv_v2 MOUNT [LOG_PREFIX]
#   Assert that the given KV mount is present and KV v2. If absent, enable
#   it. If present as wrong type/version, exit 1. Callers must have already
#   checked VAULT_ADDR / VAULT_TOKEN.
#
#   DRY_RUN (env, default 0): when 1, log intent without writing.
#   LOG_PREFIX (optional): label for log lines, e.g. "[vault-seed-forgejo]".
#
#   Extracted here because every vault-seed-*.sh script needs this exact
#   sequence, and the 5-line sliding-window dup detector flags the
#   copy-paste. One place, one implementation.
hvault_ensure_kv_v2() {
  local mount="${1:?hvault_ensure_kv_v2: MOUNT required}"
  local prefix="${2:-[hvault]}"
  local dry_run="${DRY_RUN:-0}"
  local mounts_json mount_exists mount_type mount_version

  mounts_json="$(hvault_get_or_empty "sys/mounts")" \
    || { printf '%s ERROR: failed to list Vault mounts\n' "$prefix" >&2; return 1; }

  mount_exists=false
  if printf '%s' "$mounts_json" | jq -e --arg m "${mount}/" '.[$m]' >/dev/null 2>&1; then
    mount_exists=true
  fi

  if [ "$mount_exists" = true ]; then
    mount_type="$(printf '%s' "$mounts_json" \
      | jq -r --arg m "${mount}/" '.[$m].type // ""')"
    mount_version="$(printf '%s' "$mounts_json" \
      | jq -r --arg m "${mount}/" '.[$m].options.version // "1"')"
    if [ "$mount_type" != "kv" ]; then
      printf '%s ERROR: %s/ is mounted as type=%q, expected kv — refuse to re-mount\n' \
        "$prefix" "$mount" "$mount_type" >&2
      return 1
    fi
    if [ "$mount_version" != "2" ]; then
      printf '%s ERROR: %s/ is KV v%s, expected v2 — refuse to upgrade in place\n' \
        "$prefix" "$mount" "$mount_version" >&2
      return 1
    fi
    printf '%s %s/ already mounted (kv v2) — skipping enable\n' "$prefix" "$mount"
  else
    if [ "$dry_run" -eq 1 ]; then
      printf '%s [dry-run] would enable %s/ as kv v2\n' "$prefix" "$mount"
    else
      local payload
      payload="$(jq -n '{type:"kv",options:{version:"2"},description:"disinto shared KV v2 (S2.4)"}')"
      _hvault_request POST "sys/mounts/${mount}" "$payload" >/dev/null \
        || { printf '%s ERROR: failed to enable %s/ as kv v2\n' "$prefix" "$mount" >&2; return 1; }
      printf '%s %s/ enabled as kv v2\n' "$prefix" "$mount"
    fi
  fi
}

# hvault_kv_get PATH [KEY]
#   Read a KV v2 secret at PATH, optionally extract a single KEY.
#   Outputs: JSON value (full data object, or single key value)
hvault_kv_get() {
  local path="${1:-}"
  local key="${2:-}"

  if [ -z "$path" ]; then
    _hvault_err "hvault_kv_get" "PATH is required" "usage: hvault_kv_get PATH [KEY]"
    return 1
  fi
  _hvault_check_prereqs "hvault_kv_get" || return 1

  local response
  response="$(_hvault_request GET "${VAULT_KV_MOUNT}/data/${path}")" || return 1

  if [ -n "$key" ]; then
    printf '%s' "$response" | jq -e -r --arg key "$key" '.data.data[$key]' 2>/dev/null || {
      _hvault_err "hvault_kv_get" "key not found" "key=$key path=$path"
      return 1
    }
  else
    printf '%s' "$response" | jq -e '.data.data' 2>/dev/null || {
      _hvault_err "hvault_kv_get" "failed to parse response" "path=$path"
      return 1
    }
  fi
}

# hvault_kv_put PATH KEY=VAL [KEY=VAL ...]
#   Write a KV v2 secret at PATH. Accepts one or more KEY=VAL pairs.
hvault_kv_put() {
  local path="${1:-}"
  shift || true

  if [ -z "$path" ] || [ $# -eq 0 ]; then
    _hvault_err "hvault_kv_put" "PATH and at least one KEY=VAL required" \
      "usage: hvault_kv_put PATH KEY=VAL [KEY=VAL ...]"
    return 1
  fi
  _hvault_check_prereqs "hvault_kv_put" || return 1

  # Build JSON payload from KEY=VAL pairs entirely via jq
  local payload='{"data":{}}'
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    if [ "$k" = "$kv" ]; then
      _hvault_err "hvault_kv_put" "invalid KEY=VAL pair" "got: $kv"
      return 1
    fi
    payload="$(printf '%s' "$payload" | jq --arg k "$k" --arg v "$v" '.data[$k] = $v')"
  done

  _hvault_request POST "${VAULT_KV_MOUNT}/data/${path}" "$payload" >/dev/null
}

# hvault_kv_list PATH
#   List keys at a KV v2 path.
#   Outputs: JSON array of key names
hvault_kv_list() {
  local path="${1:-}"

  if [ -z "$path" ]; then
    _hvault_err "hvault_kv_list" "PATH is required" "usage: hvault_kv_list PATH"
    return 1
  fi
  _hvault_check_prereqs "hvault_kv_list" || return 1

  local response
  response="$(_hvault_request LIST "${VAULT_KV_MOUNT}/metadata/${path}")" || return 1

  printf '%s' "$response" | jq -e '.data.keys' 2>/dev/null || {
    _hvault_err "hvault_kv_list" "failed to parse response" "path=$path"
    return 1
  }
}

# hvault_get_or_empty PATH
#   GET /v1/PATH. On 200, prints the raw response body to stdout (caller
#   parses with jq). On 404, prints nothing and returns 0 — caller treats
#   the empty string as "resource absent, needs create". Any other HTTP
#   status is a hard error: response body is logged to stderr as a
#   structured JSON error and the function returns 1.
#
#   Used by the sync scripts (tools/vault-apply-*.sh +
#   lib/init/nomad/vault-nomad-auth.sh) to read existing policies, roles,
#   auth-method listings, and per-role configs without triggering errexit
#   on the expected absent-resource case. `_hvault_request` is not a
#   substitute — it treats 404 as a hard error, which is correct for
#   writes but wrong for "does this already exist?" checks.
#
#   Subshell + EXIT trap: the RETURN trap does NOT fire on set-e abort,
#   so tmpfile cleanup from a function-scoped RETURN trap would leak on
#   jq/curl errors under `set -eo pipefail`. The subshell + EXIT trap
#   is the reliable cleanup boundary.
hvault_get_or_empty() {
  local path="${1:-}"

  if [ -z "$path" ]; then
    _hvault_err "hvault_get_or_empty" "PATH is required" \
      "usage: hvault_get_or_empty PATH"
    return 1
  fi
  _hvault_check_prereqs "hvault_get_or_empty" || return 1

  (
    local tmp http_code
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    http_code="$(curl -sS -o "$tmp" -w '%{http_code}' \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      "${VAULT_ADDR}/v1/${path}")" \
      || { _hvault_err "hvault_get_or_empty" "curl failed" "path=$path"; exit 1; }
    case "$http_code" in
      2[0-9][0-9]) cat "$tmp" ;;
      404)         printf '' ;;
      *)           _hvault_err "hvault_get_or_empty" "HTTP $http_code" "$(cat "$tmp")"
                   exit 1 ;;
    esac
  )
}

# hvault_policy_apply NAME FILE
#   Idempotent policy upsert — create or update a Vault policy.
hvault_policy_apply() {
  local name="${1:-}"
  local file="${2:-}"

  if [ -z "$name" ] || [ -z "$file" ]; then
    _hvault_err "hvault_policy_apply" "NAME and FILE are required" \
      "usage: hvault_policy_apply NAME FILE"
    return 1
  fi
  if [ ! -f "$file" ]; then
    _hvault_err "hvault_policy_apply" "policy file not found" "file=$file"
    return 1
  fi
  _hvault_check_prereqs "hvault_policy_apply" || return 1

  local policy_content
  policy_content="$(cat "$file")"
  local payload
  payload="$(jq -n --arg policy "$policy_content" '{"policy": $policy}')"

  _hvault_request PUT "sys/policies/acl/${name}" "$payload" >/dev/null
}

# hvault_jwt_login ROLE JWT
#   Exchange a JWT for a short-lived Vault token.
#   Outputs: client token string
hvault_jwt_login() {
  local role="${1:-}"
  local jwt="${2:-}"

  if [ -z "$role" ] || [ -z "$jwt" ]; then
    _hvault_err "hvault_jwt_login" "ROLE and JWT are required" \
      "usage: hvault_jwt_login ROLE JWT"
    return 1
  fi
  # Only need VAULT_ADDR, not VAULT_TOKEN (we're obtaining a token)
  if [ -z "${VAULT_ADDR:-}" ]; then
    _hvault_err "hvault_jwt_login" "VAULT_ADDR is not set"
    return 1
  fi

  local payload
  payload="$(jq -n --arg role "$role" --arg jwt "$jwt" \
    '{"role": $role, "jwt": $jwt}')"

  local response
  # JWT login does not require an existing token — use curl directly
  local tmpfile http_code
  tmpfile="$(mktemp)"
  http_code="$(curl -s -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$payload" \
    -o "$tmpfile" \
    "${VAULT_ADDR}/v1/auth/jwt/login")" || {
    _hvault_err "hvault_jwt_login" "curl failed"
    rm -f "$tmpfile"
    return 1
  }

  local body
  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"

  case "$http_code" in
    2[0-9][0-9])
      printf '%s' "$body" | jq -e -r '.auth.client_token' 2>/dev/null || {
        _hvault_err "hvault_jwt_login" "failed to extract client_token" "$body"
        return 1
      }
      ;;
    *)
      _hvault_err "hvault_jwt_login" "HTTP $http_code" "$body"
      return 1
      ;;
  esac
}

# hvault_token_lookup
#   Returns TTL, policies, and accessor for the current token.
#   Outputs: JSON object with ttl, policies, accessor fields
hvault_token_lookup() {
  _hvault_check_prereqs "hvault_token_lookup" || return 1

  local response
  response="$(_hvault_request GET "auth/token/lookup-self")" || return 1

  printf '%s' "$response" | jq -e '{
    ttl: .data.ttl,
    policies: .data.policies,
    accessor: .data.accessor,
    display_name: .data.display_name
  }' 2>/dev/null || {
    _hvault_err "hvault_token_lookup" "failed to parse token info"
    return 1
  }
}
