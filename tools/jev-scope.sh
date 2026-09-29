#!/usr/bin/env bash
# =============================================================================
# tools/jev-scope.sh — the factory asks Porter for a scope reading (#1597)
#
# Not a Porter verb — the verb lives on the door, `jev scope` (the shared-key
# `jev` verb at tools/edge-control/verbs/jev.sh, which reads the `scope.json`
# noul from packs/). This tool is the factory-side caller: it dials the door
# with a single ssh and passes the issue text on stdin through to it. The
# OpenRouter key stays on the droplet; this script carries only the ssh
# configuration and never prints key material.
#
# Usage:
#   printf '%s\n' "$issue_text" | bash tools/jev-scope.sh
#
# Required environment (all referenced, none hardcoded — AD-005):
#   PORTER_SSH_TARGET      the door, e.g. porter@<host>
#   PORTER_JEV_KEY         path to the factory-side private key
#   PORTER_JEV_KNOWN_HOSTS path to the known_hosts file pinned for the door
#
# Output contract — fails closed; a failed call must never look like a score.
#
#   exit 2, nothing on stdout, nothing on stderr, ssh never invoked:
#     any of the three required env vars is missing — empty target, missing
#     key file, or missing known_hosts file. Configuration is not the same
#     as a door verdict.
#
#   exit 1, nothing on stdout, exactly one line on stderr, no key material:
#     ssh failure (any non-zero), empty body, body not a JSON object, or body
#     lacking an `answers` object.
#
#   exit 0:
#     ssh exited 0 and the body is a JSON object with an `answers` object —
#     the body is echoed verbatim on stdout, unaltered: no thresholds, no
#     re-serialization, no numeric handling.
#
# The network is only ever reached through that single ssh command. No
# `accept-new` — the pinned known_hosts file decides, and a hostkey mismatch
# is a failure.
# =============================================================================
set -euo pipefail

# Required configuration. `:-` guards keep an unset var out of set -u; the
# empty/missing checks below fail closed before any network contact.
TARGET="${PORTER_SSH_TARGET:-}"
KEY="${PORTER_JEV_KEY:-}"
KNOWN="${PORTER_JEV_KNOWN_HOSTS:-}"

if [[ -z "$TARGET" ]]; then
  exit 2
fi
if [[ -z "$KEY" || ! -f "$KEY" ]]; then
  exit 2
fi
if [[ -z "$KNOWN" || ! -f "$KNOWN" ]]; then
  exit 2
fi

# The door call. stdout to a temp file (so a failed call can leak nothing to
# the script's stdout); stdin is inherited from the caller — that is the issue
# text; ssh stderr is discarded (it is never part of the output contract and
# must never carry key material).
body_file="$(mktemp)" || exit 1
trap 'rm -f "${body_file:-}"' EXIT

rc=0
ssh -i "$KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o UserKnownHostsFile="$KNOWN" \
    -o ConnectTimeout=15 \
    "$TARGET" jev scope >"$body_file" 2>/dev/null || rc=$?

if (( rc != 0 )); then
  printf 'jev-scope: ssh failed\n' >&2
  exit 1
fi

# The body must be a JSON object with an `answers` object — the shape
# verbs/jev.sh only emits when the call actually succeeded. An empty or
# whitespace-only response is not a reading; `jq -e` alone would accept it
# (it emits no values and exits 0), so reject it explicitly before the
# shape check. jq stderr is suppressed so the one stderr line is always this
# script's own.
if [[ -z "$(tr -d '[:space:]' < "$body_file")" ]]; then
  printf 'jev-scope: response is not a scope reading\n' >&2
  exit 1
fi
if ! jq -e 'type == "object" and ((.answers | type) == "object")' \
    "$body_file" >/dev/null 2>&1; then
  printf 'jev-scope: response is not a scope reading\n' >&2
  exit 1
fi

# Verbatim pass-through — the body itself, untouched.
cat "$body_file"
exit 0
