#!/usr/bin/env bash
# =============================================================================
# oak/pick.sh — ε-greedy action picker over the oak weights table
#
# Issue #1330 (oak tick-learner sprint): the weights table exists (oak/td.sh)
# but selection is still classify buckets + interval timers. This is one
# ε-greedy program: it prints one action name from the weights table.
#
# CLI:
#   oak/pick.sh WEIGHTS.json LEGAL.json
#
# LEGAL.json is exactly:
#   {"x_key":"2|0","epsilon":0,"q0":1.0,
#    "legal":["idle","dev-poll","gardener-step"]}
#
# Q values are read from the weights file's gvf.purpose.Q[x_key][action]
# (same schema as oak/td.sh). A missing Q[x_key][action] entry reads as
# q0 (optimistic). pick.sh NEVER writes the weights file and does not
# exec the chosen action — stdout is the whole output contract:
# one action name, newline, nothing else. Diagnostics go to stderr.
#
# Rules (closed):
#   1. `legal` must be non-empty; else exit 2.
#   2. Missing Q[x_key][a] reads as q0 (optimistic).
#   3. epsilon = 0: pick the legal action with the highest Q; ties go to
#      the FIRST action in the `legal` array.
#   4. epsilon > 0: if $RANDOM < epsilon * 32768, pick uniformly at random
#      from `legal` using $RANDOM; else greedy as in (3).
#   5. pick.sh does NOT add `idle`. The caller passes it in `legal` if it
#      is a legal action.
#   6. Does not exec the action. Does not update weights.
#
# Exit codes: 0 = picked, 1 = bad input (missing/invalid files, bad
# LEGAL.json shape), 2 = usage error or empty `legal`.
# =============================================================================
set -euo pipefail

log() { echo "pick: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") WEIGHTS.json LEGAL.json" >&2
}

[ "$#" -eq 2 ] || { usage; exit 2; }

WEIGHTS_FILE="$1"
LEGAL_FILE="$2"

[ -f "$LEGAL_FILE" ] || { log "legal file not found: $LEGAL_FILE"; exit 1; }
jq -e . "$LEGAL_FILE" >/dev/null 2>&1 \
  || { log "legal file is not valid JSON: $LEGAL_FILE"; exit 1; }

LEGAL_JSON="$(cat "$LEGAL_FILE")"

# Validate the required shape: string x_key, numeric epsilon/q0, legal an
# array of strings. (-n: this check uses $l only — no input stream, so jq
# >= 1.7 must not read stdin at all.)
jq -en --argjson l "$LEGAL_JSON" '
  ($l.x_key   | type == "string") and
  ($l.epsilon | type == "number") and
  ($l.q0      | type == "number") and
  ($l.legal   | type == "array") and
  ([$l.legal[] | type] | all(. == "string"))
' >/dev/null 2>&1 \
  || { log "legal JSON must be {\"x_key\":str,\"epsilon\":num,\"q0\":num,\"legal\":[str,...]}"; exit 1; }

# The legal array (separated from the LEGAL.json object so jq programs can
# iterate it directly).
LEGAL_ARR="$(jq -c '.legal' <<<"$LEGAL_JSON")"

# Rule 1: legal must be non-empty.
N_LEGAL="$(jq -r 'length' <<<"$LEGAL_ARR")"
if [ "$N_LEGAL" -lt 1 ]; then
  log "legal list is empty — nothing to pick"
  exit 2
fi

XKEY="$(jq -r '.x_key' <<<"$LEGAL_JSON")"
Q0="$(jq -r '.q0' <<<"$LEGAL_JSON")"
EPSILON="$(jq -r '.epsilon' <<<"$LEGAL_JSON")"

# Weights file: missing → empty table (every action reads as q0). Invalid
# JSON is a real error. pick.sh never writes the file.
if [ -f "$WEIGHTS_FILE" ]; then
  if ! WEIGHTS_JSON="$(jq -c . "$WEIGHTS_FILE" 2>/dev/null)"; then
    log "weights file is not valid JSON: $WEIGHTS_FILE"
    exit 1
  fi
else
  log "weights file missing, treating as empty table: $WEIGHTS_FILE"
  WEIGHTS_JSON='{"q0":1.0,"gvf":{"purpose":{"Q":{}},"inbound":{"V":{}}}}'
fi

# Greedy: highest Q among `legal`, missing entries → q0, ties → first in
# the legal array (map order is preserved, so the first max wins).
greedy_pick() {
  jq -rn \
    --arg xk "$XKEY" \
    --argjson q0 "$Q0" \
    --argjson legal "$LEGAL_ARR" \
    --argjson w "$WEIGHTS_JSON" '
    ($w.gvf.purpose.Q // {}) as $Q
    | [ $legal[] as $a
        | (($Q[$xk] // {}) as $row
           | (if ($row | type) == "object"
                then (if ($row[$a] | type) == "number" then $row[$a] else $q0 end)
                else $q0 end)) as $q
        | { a: $a, q: $q } ]
    | (map(.q) | max) as $best
    | (map(select(.q == $best)) | .[0].a)
  '
}

ACTION=""
if jq -en --argjson e "$EPSILON" '$e > 0' >/dev/null; then
  # Rule 4: $RANDOM is 0..32767, so epsilon*32768 is the exploration cut.
  # Floats via jq, never bash arithmetic.
  THRESHOLD="$(jq -n --argjson e "$EPSILON" '$e * 32768')"
  R1="$RANDOM"
  if jq -en --argjson r "$R1" --argjson t "$THRESHOLD" '$r < $t' >/dev/null; then
    R2="$RANDOM"
    IDX=$(( R2 % N_LEGAL ))
    ACTION="$(jq -r --argjson i "$IDX" '.legal[$i]' <<<"$LEGAL_JSON")"
  else
    ACTION="$(greedy_pick)"
  fi
else
  # Rule 3.
  ACTION="$(greedy_pick)"
fi

[ -n "$ACTION" ] || { log "no action picked (internal error)"; exit 1; }

# stdout: exactly one action name, newline, nothing else.
printf '%s\n' "$ACTION"
