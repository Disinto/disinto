#!/usr/bin/env bash
# =============================================================================
# porter-dns.sh — ensure the wildcard A record once, never edit other names
#
# Root script (not a verb): run directly by the operator on the jump host:
#   bash tools/edge-control/porter-dns.sh [--set-wildcard]
#
# Guarantees exactly one A record named `*` in zone ${DOMAIN_SUFFIX}
# (default disinto.ai) on Gandi LiveDNS v5. Value is:
#   * $PORTER_PUBLIC_IP if set (the only seam; used by acceptance tests)
#   * otherwise the host's primary global IPv4 — derived from local
#     interfaces, never an external IP-echo service.
#
# Behavior:
#   * A record absent,                create it (one POST .../records), exit 0
#   * A record present, same IP,      do nothing, exit 0
#   * A record present, different IP: no --set-wildcard  -> exit non-zero,
#     print the current value (never the token), change nothing;
#     --set-wildcard -> update only that record (one PUT .../records/<id>)
#
# Hard guarantees (AD-005 style):
#   * Never PUTs a zone: the only PUT ever issued is on a single record id.
#   * Never requests a name other than `*`: the only record name sent to the
#     API is `*`; the record list GET is name-agnostic.
#   * Never touches `@`, `www`, `self`, `NS`, or `MX`: no such name or
#     path appears anywhere in this script.
#   * The Gandi token is never printed (stdout or stderr), never written to
#     the ledger or any Caddy configuration, and exists only inside curl's
#     Authorization header.
#
# Token file (both paths are PORTER_ROOT-prefixed):
#   ${PREFIX}etc/caddy/gandi.env   if that file exists, else
#   ${PREFIX}etc/porter/gandi.env
#   KEY=value lines (install.sh writes GANDI_API_KEY=...), mode 600,
#   root-owned. Missing file, empty key, or a world-readable file => die with
#   a message that never contains the token.
#
# PORTER_ROOT: when set/non-empty (acceptance tests), every path is prefixed
# with it instead of "/".
# =============================================================================
set -euo pipefail

log() { printf 'porter-dns: %s\n' "$*"; }
die() { printf 'porter-dns: %s\n' "$*" >&2; exit 1; }

# ── Paths (PORTER_ROOT prefix when set) ──────────────────────────────────────
if [[ -n "${PORTER_ROOT:-}" ]]; then
  PREFIX="${PORTER_ROOT%/}/"
else
  PREFIX="/"
fi

# ── Arguments ─────────────────────────────────────────────────────────────────
usage() {
  printf 'Usage: %s [--set-wildcard]\n' "${BASH_SOURCE[0]}"
}

SET_WILDCARD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set-wildcard)
      SET_WILDCARD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown option: $1"
      ;;
  esac
done

# ── Token: caddy file first, porter fallback. Never printed. ─────────────────
resolve_token() {
  local caddy_env="${PREFIX}etc/caddy/gandi.env"
  local porter_env="${PREFIX}etc/porter/gandi.env"
  local file
  if [[ -f "$caddy_env" ]]; then
    file="$caddy_env"
  elif [[ -f "$porter_env" ]]; then
    file="$porter_env"
  else
    die "gandi token file missing: ${caddy_env} or ${porter_env}"
  fi
  # The declared token-file state is mode 600, root-owned. Refuse a loose
  # file without ever printing the key.
  local mode other
  mode="$(stat -c '%a' "$file")" || die "cannot stat token file ${file}"
  other=$(( (10#"$mode") % 100 % 10 ))
  if (( other != 0 )); then
    die "gandi token file is world-readable (mode $mode); chmod 600 and retry"
  fi
  local line value
  line="$(grep -m1 -E '^GANDI_API_KEY=' "$file" 2>/dev/null || true)"
  [[ -n "${line:-}" ]] || die "gandi token file has no GANDI_API_KEY line: $file"
  value="${line#GANDI_API_KEY=}"
  value="${value%$'\r'}"
  [[ -n "$value" ]] || die "gandi token file carries an empty GANDI_API_KEY: $file"
  printf '%s' "$value"
}
TOKEN="$(resolve_token)"

# ── Value: $PORTER_PUBLIC_IP (test seam) or the primary global IPv4 ──────────
# Never consults an external IP-echo service: the address is derived from
# local interfaces, loopback/link-local/private ranges excluded.

_is_global_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a b c d
  a=$((10#"${BASH_REMATCH[1]}"))
  b=$((10#"${BASH_REMATCH[2]}"))
  c=$((10#"${BASH_REMATCH[3]}"))
  d=$((10#"${BASH_REMATCH[4]}"))
  if (( a > 255 || b > 255 || c > 255 || d > 255 )); then return 1; fi
  case "$a.$b.$c.$d" in
    0.*|255.*|127.*) return 1 ;;   # reserved / loopback
    10.*|192.168.*|169.254.*) return 1 ;;  # RFC1918 + link-local
  esac
  if (( a == 172 && b >= 16 && b <= 31 )); then return 1; fi
  if (( a == 100 && b >= 64 && b <= 127 )); then return 1; fi
  if (( a == 198 && b == 18 )); then return 1; fi
  return 0
}

_primary_global_ipv4() {
  local ip line
  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      [[ "$line" =~ inet\ ([0-9.]+) ]] || continue
      ip="${BASH_REMATCH[1]%%/*}"
      if _is_global_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
      fi
    done < <(ip -4 -o addr show scope global 2>/dev/null || true)
  fi
  local ifn
  for ifn in /sys/class/net/*/address; do
    [[ -f "$ifn" ]] || continue
    ip="$(cat "$ifn" 2>/dev/null || true)"
    if _is_global_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  if command -v ifconfig >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      [[ "$line" =~ inet[[:space:]]+([0-9.]+) ]] || continue
      ip="${BASH_REMATCH[1]}"
      if _is_global_ipv4 "$ip"; then
        printf '%s\n' "$ip"
        return 0
      fi
    done < <(ifconfig -a 2>/dev/null || true)
  fi
  return 1
}

resolve_ip() {
  if [[ -n "${PORTER_PUBLIC_IP:-}" ]]; then
    printf '%s\n' "$PORTER_PUBLIC_IP"
    return 0
  fi
  _primary_global_ipv4 || die "cannot determine the host's primary global IPv4 (no global address on any interface)"
}
IP="$(resolve_ip)"

# ── Gandi LiveDNS v5 calls: the token only ever rides the Authorization
#     header; response bodies are never echoed to stdout/stderr. ──────────────
GANDI_BASE="https://api.gandi.net/v5"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-disinto.ai}"

_gandi() {
  local method="$1" path="$2" body="${3:-}"
  local args=()
  local resp
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  resp="$(curl -fsSL -X "$method" -H "Authorization: Bearer ${TOKEN}" \
    "${GANDI_BASE}${path}" "${args[@]}" 2>/dev/null)" || {
    die "gandi API ${method} ${path} failed"
  }
  printf '%s' "$resp"
}

# ── Current state ─────────────────────────────────────────────────────────────
records_path="/domains/${DOMAIN_SUFFIX}/records"
records_body="$( _gandi GET "$records_path" )"
jq -e . <<<"$records_body" >/dev/null 2>&1 || die "gandi API GET ${records_path}: response is not JSON"

# The single record this script knows about: A record named `*`.
wildcard_id=""
wildcard_value=""
if [[ -n "$records_body" ]]; then
  wildcard_id="$(jq -r '.data[]? | select(.type == "A" and .name == "*") | .id // empty' <<<"$records_body" | head -n1)"
  wildcard_value="$(jq -r '.data[]? | select(.type == "A" and .name == "*") | (.value_list[0] // .value // empty)' <<<"$records_body" | head -n1)"
fi

# {"name":"*","type":"A","value":"<ip>"} — the only body shape ever sent.
record_body() {
  jq -cn --arg name '*' --arg ip "$IP" '{name: $name, type: "A", value: $ip}'
}

if [[ -z "$wildcard_id" && -z "$wildcard_value" ]]; then
  # Absent: create it. This is the only write that may touch the zone.
  _gandi POST "$records_path" "$(record_body)" >/dev/null
  log "created * A record for ${DOMAIN_SUFFIX} -> ${IP}"
  exit 0
fi

if [[ "$wildcard_value" == "$IP" ]]; then
  log "* A record for ${DOMAIN_SUFFIX} already ${IP}; nothing to do"
  exit 0
fi

if [[ $SET_WILDCARD -eq 1 ]]; then
  # Present with a different value: update only this one record.
  _gandi PUT "${records_path}/${wildcard_id}" "$(record_body)" >/dev/null
  log "updated * A record for ${DOMAIN_SUFFIX} -> ${IP}"
  exit 0
fi

# Present with a different value, without --set-wildcard: refuse and print
# the current value (never the token).
log "wildcard * A record for ${DOMAIN_SUFFIX} is ${wildcard_value}, expected ${IP}; re-run with --set-wildcard to update it"
exit 1
