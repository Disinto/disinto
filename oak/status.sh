#!/usr/bin/env bash
# =============================================================================
# oak/status.sh — one command for the live learner's last tick
#
# Issue #1352: watching the live learner meant jq on three files. This prints
# the last action, the last key, r, and the purpose-Q row for that key.
#
# CLI:
#   oak/status.sh   (no args)
#
# Reads (never writes) $OPS_REPO_ROOT/oak/:
#   last.json         — the previous tick {x_key, a, x} → last action + key
#   transitions.jsonl — last line → r (the last learned transition's reward)
#   weights.json      — gvf.purpose.Q[x_key] → the Q row for the last key
#
# Stdout (human-readable, four lines; the Q_ROW value is one JSON object):
#   last_action: <a>
#   last_key: <x_key>
#   r: <r>
#   Q_ROW={"<action>":<q>,...}
# Q_ROW is {} when weights.json is missing/invalid or has no row for the
# last key. r is (none) when transitions.jsonl has no last line.
#
# If last.json is missing: stdout is `boot: no last.json`, exit 0 (the first
# tick is a boot — there is no previous tick to report).
#
# Read-only: does not write weights, does not start organs.
#
# Exit codes: 0 = printed (or booted), 2 = OPS_REPO_ROOT unset or args given.
# =============================================================================
set -euo pipefail

log() { echo "status: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") — no args; reads \$OPS_REPO_ROOT/oak/ (last.json, weights.json, transitions.jsonl)" >&2
}

[ "$#" -eq 0 ] || { usage; exit 2; }
[ -n "${OPS_REPO_ROOT:-}" ] || { usage; exit 2; }

OAK_DIR="$OPS_REPO_ROOT/oak"
LAST_FILE="$OAK_DIR/last.json"
WEIGHTS_FILE="$OAK_DIR/weights.json"
TRANS_FILE="$OAK_DIR/transitions.jsonl"

[ -f "$LAST_FILE" ] || { echo "boot: no last.json"; exit 0; }

LAST_A=""
LAST_KEY=""
if ! LAST_JSON="$(jq -c . "$LAST_FILE" 2>/dev/null)"; then
  log "last.json is not valid JSON — fields will be empty: $LAST_FILE"
else
  LAST_A="$(jq -r '.a // empty' <<<"$LAST_JSON")"
  LAST_KEY="$(jq -r '.x_key // empty' <<<"$LAST_JSON")"
fi

# r: the reward on the LAST line of transitions.jsonl (the last learned
# transition). Missing/empty file → (none).
R="(none)"
if [ -f "$TRANS_FILE" ]; then
  LAST_LINE="$(tail -n1 "$TRANS_FILE" || true)"
  if [ -n "$LAST_LINE" ]; then
    R="$(jq -r '.r // empty' <<<"$LAST_LINE" 2>/dev/null || true)"
    [ -n "$R" ] || R="(none)"
  fi
fi

# Q_ROW: the purpose-Q map for the last key, one compact JSON object;
# {} when weights.json is missing/invalid or has no row for the key.
Q_ROW="{}"
if [ -f "$WEIGHTS_FILE" ]; then
  Q_ROW="$(jq -c --arg k "$LAST_KEY" \
    '.gvf.purpose.Q[$k] // {}' "$WEIGHTS_FILE" 2>/dev/null || true)"
  [ -n "$Q_ROW" ] || Q_ROW="{}"
fi

echo "last_action: $LAST_A"
echo "last_key: $LAST_KEY"
echo "r: $R"
echo "Q_ROW=$Q_ROW"
