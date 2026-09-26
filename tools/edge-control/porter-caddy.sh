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
# deleted or rewritten. No catch-all :80/:443 site is ever written (Porter
# does not listen on 80/443 — the customer is a Caddy route). This script
# never becomes an HTTP server.
#
# Fresh install writes a NEW Caddyfile whose entire content is:
#   {
#     admin localhost:2019
#   }
#
#   import <prefix>/etc/caddy/extra.d/*.caddy
#
# and creates `extra.d` if missing. Operator sites remain as files in
# `extra.d`; nothing else is written.
#
# PORTER_ROOT prefixing: when PORTER_ROOT is set/non-empty (acceptance tests),
# every path is prefixed with it and every real-host action (downloading/running
# the caddy binary, `caddy validate`, `caddy reload`) is skipped.
# On a real host, a successful file edit is followed by `caddy validate`; only
# on a passing validate is Caddy reloaded. A failed validate restores the
# previous Caddyfile and does NOT reload.
#
# The Caddy systemd unit is install.sh's responsibility; this script never
# writes or rewrites it, so it cannot replace existing site config.
#
# This script does not call install.sh and requires no token of any kind
# (AD-005). It must not be sourced by verbs — verbs use lib/caddy.sh for
# route management only.
# =============================================================================
set -euo pipefail

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
  if ! "$tmp" version 2>&1 | grep -qi gandi; then
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

  # The NEW Caddyfile: global block + import only. No site blocks, no catch-
  # all :80/:443, no self/www/apex/customer sites.
  printf '{\n  admin localhost:2019\n}\n\nimport %s\n' "$EXTRA_IMPORT" > "$CADDYFILE"
  chmod 644 "$CADDYFILE"

  if [[ $TEST_MODE -eq 0 ]]; then
    install_caddy_binary
    if ! "$CADDY_BIN" validate --config "$CADDYFILE" >/dev/null 2>&1; then
      die "caddy validate failed after install"
    fi
    # The Caddy systemd unit is owned by install.sh (the optional Caddy
    # installer). This script never rewrites it, so it cannot replace site
    # config. Enable it on the host: systemctl enable --now caddy
    log "caddy binary + Caddyfile installed (validate OK); enable the caddy service via systemd (the optional Caddy installer owns that unit)"
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

exit 0
