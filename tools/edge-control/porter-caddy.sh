#!/usr/bin/env bash
# =============================================================================
# porter-caddy.sh — Caddy adoption / install for the Porter edge door
#
# Root script (not a verb), run directly by the Porter installer or an operator:
#   bash tools/edge-control/porter-caddy.sh
#
# Two modes, selected by what already exists under PORTER_ROOT:
#
#   ADOPT   prefix/etc/caddy/Caddyfile exists  OR  prefix/usr/bin/caddy exists
#   INSTALL neither exists (fresh prefix, no Caddy at all)
#
# The ONLY thing this script may ever change in an existing Caddyfile is
# inserting `admin localhost:2019` into the global options block when that
# exact admin listener is not yet configured. Site blocks are left
# byte-for-byte. No site blocks, `extra.d` files, or server config are ever
# deleted or rewritten. A catch-all :80/:443 site is never written (Porter
# does not listen on 80/443 — the customer is a Caddy route).
#
# Fresh install writes a NEW Caddyfile:
#
#   {
#     admin localhost:2019
#   }
#
#   import <prefix>/etc/caddy/extra.d/*.caddy
#
#   *.<domain> {
#     tls acme {
#       dns gandi {env.GANDI_API_KEY}
#       propagation_delay 20s
#       propagation_timeout 10m
#       resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net
#     }
#   }
#
# plus `extra.d` created if missing. The wildcard site (address *.<domain>,
# default disinto.ai) is the only site: no self/, www/, apex, or customer
# site, no catch-all :80/:443. Its only directive is the wildcard cert — the
# ACME issuer (tls acme, gandi DNS plugin) with a 20s propagation delay and
# a 10m propagation timeout, so Caddy keeps polling the Gandi nameservers
# until the TXT propagates instead of giving up after ~2 minutes, plus the
# Gandi resolvers. Caddy listens on 443 and add_route finds a server on
# :443 for the exact-host routes that arrive later. Operator sites remain
# as files in `extra.d`; the import stays, so a more specific extra.d file
# wins over the wildcard.
#
# PORTER_ROOT prefixing: when PORTER_ROOT is set/non-empty (acceptance tests),
# every path is prefixed with it and every real-host action (downloading/running
# the caddy binary, `caddy validate`, `caddy reload`, `systemctl`) is skipped.
# On a real host, a successful file edit is followed by `caddy validate`; only
# on a passing validate is Caddy reloaded (adopt mode). A failed validate
# restores the previous Caddyfile and does NOT reload. A fresh install on a
# real host additionally calls `systemctl enable --now caddy` after a passing
# validate; a failed validate exits non-zero and never enables.
#
# A fresh install writes ${prefix}etc/systemd/system/caddy.service only when
# no caddy.service exists under ${prefix}etc/systemd/system or
# ${prefix}lib/systemd/system — it never overwrites an existing unit. The unit
# runs `${CADDY_BIN} run --config` the Caddyfile and loads
# ${prefix}etc/caddy/gandi.env with `EnvironmentFile=-` (missing token does not
# stop it); it never contains the token.
#
# After a successful adopt OR install this script mounts the Stripe webhook as
# ONE PATH on the existing Caddy: it sources lib/caddy.sh and calls
# add_webhook_route, which POSTs a single route /stripe/webhook ->
# 127.0.0.1:9088 (the port the operator runs the per-request invoker on,
# see tools/edge-control/stripe-webhook.sh). It is never a new HTTP server,
# never a PUT /config/, and never touches any other route or site block;
# add_webhook_route is idempotent (no-op when the path route already exists),
# so re-running this script is safe.
#
# This script does not call install.sh and requires no token of any kind
# (AD-005). It must not be sourced by verbs — verbs use lib/caddy.sh for
# route management only.
# =============================================================================
set -euo pipefail

# Source the Caddy admin-route helpers (add_route / remove_route /
# add_webhook_route / reload_caddy). They have no main(); safe to source
# alongside this script's own set -euo pipefail.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/caddy.sh
source "${SCRIPT_DIR}/lib/caddy.sh"

# ── Paths (PORTER_ROOT prefixed when set) ─────────────────────────────────────
if [[ -n "${PORTER_ROOT:-}" ]]; then
  PREFIX="${PORTER_ROOT%/}/"
  TEST_MODE=1
else
  PREFIX="/"
  TEST_MODE=0
fi

CADDYFILE="${PREFIX}etc/caddy/Caddyfile"
EXTRA_DIR="${PREFIX}etc/caddy/extra.d"
EXTRA_IMPORT="${EXTRA_DIR}/*.caddy"
CADDY_BIN="${PREFIX}usr/bin/caddy"

log() {
  printf 'porter-caddy: %s\n' "$1"
}

die() {
  printf 'porter-caddy: %s\n' "$*" >&2
  exit 1
}

# ── Global options block helpers ──────────────────────────────────────────────
# Print "open close" (1-based line numbers) of the global options block: the
# first line containing exactly `{` (no other characters) and the next line
# containing exactly `}`. Print "0 0" if no such block exists.
_find_global_block() {
  local caddyfile="$1"
  local open=0 close=0 i line stripped
  i=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    i=$((i + 1))
    stripped="${line//[[:space:]]/}"
    if [[ $open -eq 0 ]]; then
      if [[ "$stripped" == "{" ]]; then
        open=$i
      fi
    elif [[ "$stripped" == "}" ]]; then
      close=$i
      break
    fi
  done < "$caddyfile"
  printf '%s %s\n' "$open" "$close"
}

# True if the global options block (between the open and close lines) already
# carries `admin localhost:2019`.
_admin_configured() {
  local caddyfile="$1" open="$2" close="$3"
  local i line stripped
  for ((i = open + 1; i < close; i++)); do
    line="$(sed -n "${i}p" "$caddyfile")"
    stripped="${line//[[:space:]]/}"
    if [[ "$stripped" == "adminlocalhost:2019" ]]; then
      return 0
    fi
  done
  return 1
}

# True if everything from the global block's closing brace onward is byte-for-
# byte identical in the original file and the candidate edit (shifted by one
# line because of the single inserted line).
_verify_site_blocks_preserved() {
  local orig="$1" new="$2" close="$3"
  local t1 t2
  t1="${orig}.verify.tail.orig"
  t2="${new}.verify.tail.new"
  sed -n "${close},\$p" "$orig" > "$t1" || { rm -f "$t1" "$t2"; return 1; }
  sed -n "$((close + 1)),\$p" "$new" > "$t2" || { rm -f "$t1" "$t2"; return 1; }
  local ok=0
  if cmp -s "$t1" "$t2"; then
    ok=0
  else
    ok=1
  fi
  rm -f "$t1" "$t2"
  return $ok
}

# ── Mode: ADOPT ───────────────────────────────────────────────────────────────
adopt() {
  local caddyfile="$CADDYFILE"
  if [[ ! -f "$caddyfile" ]]; then
    die "adopt mode requires an existing Caddyfile at ${CADDYFILE}"
  fi

  local open close
  read -r open close < <(_find_global_block "$caddyfile")

  if [[ "$open" == "0" || "$close" == "0" ]]; then
    die "no global options block found in ${caddyfile}; refusing to modify (would have to touch site blocks)"
  fi

  if _admin_configured "$caddyfile" "$open" "$close"; then
    log "admin listener already configured; ${caddyfile} left untouched"
    return 0
  fi

  # Real-host backup so a failed `caddy validate` can restore the previous
  # Caddyfile. No backup file is created in TEST_MODE.
  local backup="${caddyfile}.bak"
  if [[ $TEST_MODE -eq 0 ]]; then
    cp "$caddyfile" "$backup"
  fi

  # The only permitted edit: insert `admin localhost:2019` right after the
  # global options block's opening brace.
  local tmp="${caddyfile}.tmp"
  awk -v open="$open" '
    NR == open { print; print "  admin localhost:2019"; next }
    { print }
  ' "$caddyfile" > "$tmp" || {
    rm -f "${caddyfile}.tmp"
    rm -f "$backup"
    die "cannot write temporary Caddyfile"
  }

  # Hard safety net: the closing brace and every line after it (all site
  # blocks, imports, anything) must be byte-for-byte identical.
  if ! _verify_site_blocks_preserved "$caddyfile" "$tmp" "$close"; then
    rm -f "$tmp" "$backup"
    die "edit would alter content outside the global options block; no change made"
  fi

  mv "$tmp" "$caddyfile"
  log "inserted 'admin localhost:2019' into global options block of ${caddyfile}"

  # Real host only: validate, then reload. A failed validate restores the
  # previous Caddyfile and does NOT reload.
  if [[ $TEST_MODE -eq 0 ]]; then
    if ! "$CADDY_BIN" validate --config "$caddyfile" >/dev/null 2>&1; then
      cp "$backup" "$caddyfile"
      rm -f "$backup"
      die "caddy validate failed; previous Caddyfile restored"
    fi
    if ! "$CADDY_BIN" reload --config "$caddyfile" >/dev/null 2>&1; then
      rm -f "$backup"
      die "caddy reload failed after a passing validate"
    fi
    rm -f "$backup"
    log "caddy validated and reloaded"
  fi
}

# ── Mode: INSTALL (fresh, no Caddyfile, no binary) ───────────────────────────
install_caddy_binary() {
  local api_url="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/gandi"
  local tmp
  tmp="$(mktemp /tmp/caddy-1555.XXXXXX)" || die "cannot create temp file"
  trap 'rm -f "$tmp"' RETURN 2>/dev/null || true
  curl -fsSL --max-time 600 "$api_url" -o "$tmp" || {
    rm -f "$tmp"
    die "caddy download failed"
  }
  chmod +x "$tmp" || die "cannot make temporary caddy executable"
  # Caddy prints only the version line from `version` — the plugin's presence
  # lives in `list-modules` (a line like dns.providers.gandi). Detect the
  # plugin there, not the version string (2.11.4 shows no `gandi` in the
  # version output).
  if ! "$tmp" list-modules 2>&1 | grep -qF 'dns.providers.gandi'; then
    rm -f "$tmp"
    die "downloaded caddy binary does not contain the gandi plugin"
  fi
  mkdir -p "$(dirname "$CADDY_BIN")"
  mv "$tmp" "$CADDY_BIN"
  log "installed caddy with gandi plugin: ${CADDY_BIN}"
}

install() {
  log "fresh install: creating ${EXTRA_DIR} and ${CADDYFILE}"

  # extra.d holds operator site blocks. Create only if missing.
  mkdir -p "$EXTRA_DIR"

  # The NEW Caddyfile: global block + import + exactly one site block — the
  # wildcard *.<DOMAIN_SUFFIX> (default disinto.ai). The block's only
  # directive is the wildcard cert: the ACME issuer (tls acme, gandi DNS
  # plugin with env.GANDI_API_KEY, a 20s propagation delay, a 10m
  # propagation timeout, and the Gandi resolvers) — no other issuer, no
  # staging CA — no reverse_proxy, no self/, www/, apex, or customer site,
  # no catch-all :80/:443. This gives add_route a server on :443 to hang
  # exact-host routes on. Customer routes arrive later as one exact-host POST.
  local domain="${DOMAIN_SUFFIX:-disinto.ai}"
  printf '{\n  admin localhost:2019\n}\n\nimport %s\n\n*.%s {\n  tls acme {\n    dns gandi {env.GANDI_API_KEY}\n    propagation_delay 20s\n    propagation_timeout 10m\n    resolvers ns-163-a.gandi.net ns-102-b.gandi.net ns-91-c.gandi.net\n  }\n}\n' \
    "$EXTRA_IMPORT" "$domain" > "$CADDYFILE"
  chmod 644 "$CADDYFILE"
  log "wrote ${CADDYFILE} with the *.$domain wildcard cert site"

  # caddy.service (fresh install only): written at
  # ${PREFIX}etc/systemd/system/caddy.service only when no caddy.service
  # already exists under ${PREFIX}etc/systemd/system or
  # ${PREFIX}lib/systemd/system — an existing unit is never overwritten. It
  # runs ${CADDY_BIN} run --config the Caddyfile and loads
  # ${PREFIX}etc/caddy/gandi.env with EnvironmentFile=- so a missing token
  # never stops the process; the unit contains no token.
  local unit_file unit_lib gandi_env
  unit_file="${PREFIX}etc/systemd/system/caddy.service"
  unit_lib="${PREFIX}lib/systemd/system/caddy.service"
  gandi_env="${PREFIX}etc/caddy/gandi.env"
  if [[ ! -f "$unit_file" && ! -f "$unit_lib" ]]; then
    mkdir -p "$(dirname "$unit_file")"
    printf '[Unit]\nDescription=Caddy HTTP/HTTPS web server\nAfter=network.target network-online.target\nWants=network-online.target\n\n[Service]\nType=notify\nEnvironmentFile=-%s\nExecStart=%s run --config %s\nRestart=on-failure\nRestartSec=5\n\n[Install]\nWantedBy=multi-user.target\n\n' \
      "$gandi_env" "$CADDY_BIN" "$CADDYFILE" > "$unit_file"
    chmod 644 "$unit_file"
    log "wrote ${unit_file}"
  else
    log "caddy.service already present; not touching it"
  fi

  if [[ $TEST_MODE -eq 0 ]]; then
    install_caddy_binary
    if ! "$CADDY_BIN" validate --config "$CADDYFILE" >/dev/null 2>&1; then
      die "caddy validate failed after install"
    fi
    systemctl enable --now caddy
    log "caddy validated and enabled via systemctl enable --now caddy"
  fi

  log "fresh install complete"
}

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ -f "$CADDYFILE" ]] || [[ -f "$CADDY_BIN" ]]; then
  log "mode: adopt (existing Caddyfile at ${CADDYFILE} or caddy binary at ${CADDY_BIN})"
  adopt
else
  log "mode: install (no Caddyfile at ${CADDYFILE} and no caddy binary at ${CADDY_BIN})"
  install
fi

# Both modes now leave a Caddy with an admin listener. Mount the Stripe
# webhook as ONE PATH (/stripe/webhook -> 127.0.0.1:9088) on that existing
# Caddy. Never a new server, never a PUT /config/, and never touching any
# other route (site blocks, other project routes, a self.disinto.ai stub, etc.).
# add_webhook_route is idempotent (no-op when the path route is already
# present), so re-running porter-install / porter-caddy is safe.
#
# A failed add is loud but NOT fatal: on a real fresh install the caddy
# service may not be listening on 2019 yet (a fresh install enables it via
# systemctl; on an existing install the operator may start caddy manually),
# so the route is logged as PENDING rather than aborting an otherwise
# successful install. Re-run once caddy is up and it will land.
if add_webhook_route; then
  log "stripe webhook path route is live on the existing Caddy"
else
  log "ERROR: add_webhook_route failed (Caddy admin unreachable?); the /stripe/webhook route is PENDING — run this script again once caddy is listening on localhost:2019"
fi

exit 0
