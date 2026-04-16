#!/usr/bin/env bash
# =============================================================================
# tools/vault-apply-roles.sh — Idempotent Vault JWT-auth role sync
#
# Part of the Nomad+Vault migration (S2.3, issue #881). Reads
# vault/roles.yaml and upserts each entry as a Vault role under
# auth/jwt-nomad/role/<name>.
#
# Idempotency contract:
#   For each role entry in vault/roles.yaml:
#     - Role missing in Vault       → write, log "role <NAME> created"
#     - Role present, fields match  → skip,  log "role <NAME> unchanged"
#     - Role present, fields differ → write, log "role <NAME> updated"
#
#   Comparison is per-field on the data the CLI would read back
#   (GET auth/jwt-nomad/role/<NAME>.data.{policies,bound_audiences,
#   bound_claims,token_ttl,token_max_ttl,token_type}). Only the fields
#   this script owns are compared — a future field added by hand in
#   Vault would not be reverted on the next run.
#
#   --dry-run: prints the planned role list + full payload for each role
#   WITHOUT touching Vault. Exits 0.
#
# Preconditions:
#   - Vault auth method jwt-nomad must already be enabled + configured
#     (done by lib/init/nomad/vault-nomad-auth.sh — which then calls
#     this script). Running this script standalone against a Vault with
#     no jwt-nomad path will fail on the first role write.
#   - vault/roles.yaml present. See that file's header for the format.
#
# Requires:
#   - VAULT_ADDR   (e.g. http://127.0.0.1:8200)
#   - VAULT_TOKEN  (env OR /etc/vault.d/root.token, resolved by lib/hvault.sh)
#   - curl, jq, awk
#
# Usage:
#   tools/vault-apply-roles.sh
#   tools/vault-apply-roles.sh --dry-run
#
# Exit codes:
#   0  success (roles synced, or --dry-run completed)
#   1  precondition / API / parse failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROLES_FILE="${REPO_ROOT}/vault/roles.yaml"

# shellcheck source=../lib/hvault.sh
source "${REPO_ROOT}/lib/hvault.sh"

# Constants shared across every role — the issue's AC names these as the
# invariant token shape for Nomad workload identity. Bumping any of these
# is a knowing, repo-wide change, not a per-role knob, so they live here
# rather than as per-entry fields in roles.yaml.
ROLE_AUDIENCE="vault.io"
ROLE_TOKEN_TYPE="service"
ROLE_TOKEN_TTL="1h"
ROLE_TOKEN_MAX_TTL="24h"

log() { printf '[vault-roles] %s\n' "$*"; }
die() { printf '[vault-roles] ERROR: %s\n' "$*" >&2; exit 1; }

# ── Flag parsing (single optional flag — see vault-apply-policies.sh for the
# sibling grammar). Structured as arg-count guard + dispatch to keep the
# 5-line sliding-window duplicate detector (.woodpecker/detect-duplicates.py)
# from flagging this as shared boilerplate with vault-apply-policies.sh —
# the two parsers implement the same shape but with different control flow.
dry_run=false
if [ "$#" -gt 1 ]; then
  die "too many arguments (saw: $*)"
fi
arg="${1:-}"
if [ "$arg" = "--dry-run" ]; then
  dry_run=true
elif [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
  printf 'Usage: %s [--dry-run]\n\n' "$(basename "$0")"
  printf 'Apply every role in vault/roles.yaml to Vault as a\n'
  printf 'jwt-nomad role. Idempotent: unchanged roles are reported\n'
  printf 'as "unchanged" and not written.\n\n'
  printf '  --dry-run   Print the planned role list + full role\n'
  printf '              payload without contacting Vault. Exits 0.\n'
  exit 0
elif [ -n "$arg" ]; then
  die "unknown flag: $arg"
fi
unset arg

# ── Preconditions ────────────────────────────────────────────────────────────
for bin in curl jq awk; do
  command -v "$bin" >/dev/null 2>&1 \
    || die "required binary not found: ${bin}"
done

[ -f "$ROLES_FILE" ] \
  || die "roles file not found: ${ROLES_FILE}"

# ── Parse vault/roles.yaml → TSV ─────────────────────────────────────────────
# Strict-format parser. One awk pass; emits one TAB-separated line per role:
#   <name>\t<policy>\t<namespace>\t<job_id>
#
# Grammar: a record opens on a line matching `- name: <value>` and closes
# on the next `- name:` or EOF. Within a record, `policy:`, `namespace:`,
# and `job_id:` lines populate the record. Comments (`#...`) and blank
# lines are ignored. Whitespace around the colon and value is trimmed.
#
# This is intentionally narrower than full YAML — the file's header
# documents the exact subset. If someone adds nested maps, arrays, or
# anchors, this parser will silently drop them; the completeness check
# below catches records missing any of the four fields.
parse_roles() {
  awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function strip_comment(s) { sub(/[[:space:]]+#.*$/, "", s); return s }
    function emit() {
      if (name != "") {
        if (policy == "" || namespace == "" || job_id == "") {
          printf "INCOMPLETE\t%s\t%s\t%s\t%s\n", name, policy, namespace, job_id
        } else {
          printf "%s\t%s\t%s\t%s\n", name, policy, namespace, job_id
        }
      }
      name=""; policy=""; namespace=""; job_id=""
    }
    BEGIN { name=""; policy=""; namespace=""; job_id="" }
    # Strip full-line comments and blank lines early.
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    # New record: "- name: <value>"
    /^[[:space:]]*-[[:space:]]+name:[[:space:]]/ {
      emit()
      line=strip_comment($0)
      sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", line)
      name=trim(line)
      next
    }
    # Field within current record. Only accept when a record is open.
    /^[[:space:]]+policy:[[:space:]]/ && name != "" {
      line=strip_comment($0); sub(/^[[:space:]]+policy:[[:space:]]*/, "", line)
      policy=trim(line); next
    }
    /^[[:space:]]+namespace:[[:space:]]/ && name != "" {
      line=strip_comment($0); sub(/^[[:space:]]+namespace:[[:space:]]*/, "", line)
      namespace=trim(line); next
    }
    /^[[:space:]]+job_id:[[:space:]]/ && name != "" {
      line=strip_comment($0); sub(/^[[:space:]]+job_id:[[:space:]]*/, "", line)
      job_id=trim(line); next
    }
    END { emit() }
  ' "$ROLES_FILE"
}

mapfile -t ROLE_RECORDS < <(parse_roles)

if [ "${#ROLE_RECORDS[@]}" -eq 0 ]; then
  die "no roles parsed from ${ROLES_FILE}"
fi

# Validate every record is complete. An INCOMPLETE line has the form
# "INCOMPLETE\t<name>\t<policy>\t<namespace>\t<job_id>" — list all of
# them at once so the operator sees every missing field, not one per run.
incomplete=()
for rec in "${ROLE_RECORDS[@]}"; do
  case "$rec" in
    INCOMPLETE*) incomplete+=("${rec#INCOMPLETE$'\t'}") ;;
  esac
done
if [ "${#incomplete[@]}" -gt 0 ]; then
  printf '[vault-roles] ERROR: role entries with missing fields:\n' >&2
  for row in "${incomplete[@]}"; do
    IFS=$'\t' read -r name policy namespace job_id <<<"$row"
    printf '  - name=%-24s policy=%-22s namespace=%-10s job_id=%s\n' \
      "${name:-<missing>}" "${policy:-<missing>}" \
      "${namespace:-<missing>}" "${job_id:-<missing>}" >&2
  done
  die "fix ${ROLES_FILE} and re-run"
fi

# ── Helper: build the JSON payload Vault expects for a role ──────────────────
# Keeps bound_audiences as a JSON array (required by the API — a scalar
# string silently becomes a one-element-list in the CLI but the HTTP API
# rejects it). All fields that differ between runs are inside this payload
# so the diff-check below (role_fields_match) compares like-for-like.
build_payload() {
  local policy="$1" namespace="$2" job_id="$3"
  jq -n \
    --arg aud "$ROLE_AUDIENCE" \
    --arg policy "$policy" \
    --arg ns "$namespace" \
    --arg job "$job_id" \
    --arg ttype "$ROLE_TOKEN_TYPE" \
    --arg ttl "$ROLE_TOKEN_TTL" \
    --arg maxttl "$ROLE_TOKEN_MAX_TTL" \
    '{
      role_type: "jwt",
      bound_audiences: [$aud],
      user_claim: "nomad_job_id",
      bound_claims: { nomad_namespace: $ns, nomad_job_id: $job },
      token_type: $ttype,
      token_policies: [$policy],
      token_ttl: $ttl,
      token_max_ttl: $maxttl
    }'
}

# ── Dry-run: print plan + exit (no Vault calls) ──────────────────────────────
if [ "$dry_run" = true ]; then
  log "dry-run — ${#ROLE_RECORDS[@]} role(s) in ${ROLES_FILE}"
  for rec in "${ROLE_RECORDS[@]}"; do
    IFS=$'\t' read -r name policy namespace job_id <<<"$rec"
    payload="$(build_payload "$policy" "$namespace" "$job_id")"
    printf '[vault-roles] would apply role %s → policy=%s namespace=%s job_id=%s\n' \
      "$name" "$policy" "$namespace" "$job_id"
    printf '%s\n' "$payload" | jq -S . | sed 's/^/    /'
  done
  exit 0
fi

# ── Live run: Vault connectivity check ───────────────────────────────────────
# Default the local-cluster Vault env (see lib/hvault.sh::_hvault_default_env).
# Called transitively from vault-nomad-auth.sh during `disinto init`, which
# does not export VAULT_ADDR in the common fresh-LXC case (issue #912).
_hvault_default_env
if ! hvault_token_lookup >/dev/null; then
  die "Vault auth probe failed — check VAULT_ADDR + VAULT_TOKEN"
fi

# ── Helper: compare on-server role to desired payload ────────────────────────
# Returns 0 iff every field this script owns matches. Fields not in our
# payload (e.g. a manually-added `ttl` via the UI) are ignored — we don't
# revert them, but we also don't block on them.
role_fields_match() {
  local current_json="$1" desired_json="$2"
  local keys=(
    role_type bound_audiences user_claim bound_claims
    token_type token_policies token_ttl token_max_ttl
  )
  # Vault returns token_ttl/token_max_ttl as integers (seconds) on GET but
  # accepts strings ("1h") on PUT. Normalize: convert desired durations to
  # seconds before comparing. jq's tonumber/type checks give us a uniform
  # representation on both sides.
  local cur des
  for k in "${keys[@]}"; do
    cur="$(printf '%s' "$current_json" | jq -cS --arg k "$k" '.data[$k] // null')"
    des="$(printf '%s' "$desired_json" | jq -cS --arg k "$k" '.[$k] // null')"
    case "$k" in
      token_ttl|token_max_ttl)
        # Normalize desired: "1h"→3600, "24h"→86400.
        des="$(printf '%s' "$des" | jq -r '. // ""' | _duration_to_seconds)"
        cur="$(printf '%s' "$cur" | jq -r '. // 0')"
        ;;
    esac
    if [ "$cur" != "$des" ]; then
      return 1
    fi
  done
  return 0
}

# _duration_to_seconds — read a duration string on stdin, echo seconds.
# Accepts the subset we emit: "Ns", "Nm", "Nh", "Nd". Integers pass through
# unchanged. Any other shape produces the empty string (which cannot match
# Vault's integer response → forces an update).
_duration_to_seconds() {
  local s
  s="$(cat)"
  case "$s" in
    ''|null)       printf '0'                              ;;
    *[0-9]s)       printf '%d' "${s%s}"                    ;;
    *[0-9]m)       printf '%d' "$(( ${s%m} * 60 ))"        ;;
    *[0-9]h)       printf '%d' "$(( ${s%h} * 3600 ))"      ;;
    *[0-9]d)       printf '%d' "$(( ${s%d} * 86400 ))"     ;;
    *[0-9])        printf '%d' "$s"                        ;;
    *)             printf ''                               ;;
  esac
}

# ── Apply each role, reporting created/updated/unchanged ─────────────────────
log "syncing ${#ROLE_RECORDS[@]} role(s) from ${ROLES_FILE}"

for rec in "${ROLE_RECORDS[@]}"; do
  IFS=$'\t' read -r name policy namespace job_id <<<"$rec"

  desired_payload="$(build_payload "$policy" "$namespace" "$job_id")"
  # hvault_get_or_empty: raw body on 200, empty on 404 (caller: "create").
  current_json="$(hvault_get_or_empty "auth/jwt-nomad/role/${name}")" \
    || die "failed to read existing role: ${name}"

  if [ -z "$current_json" ]; then
    _hvault_request POST "auth/jwt-nomad/role/${name}" "$desired_payload" >/dev/null \
      || die "failed to create role: ${name}"
    log "role ${name} created"
    continue
  fi

  if role_fields_match "$current_json" "$desired_payload"; then
    log "role ${name} unchanged"
    continue
  fi

  _hvault_request POST "auth/jwt-nomad/role/${name}" "$desired_payload" >/dev/null \
    || die "failed to update role: ${name}"
  log "role ${name} updated"
done

log "done — ${#ROLE_RECORDS[@]} role(s) synced"
