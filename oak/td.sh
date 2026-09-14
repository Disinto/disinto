#!/usr/bin/env bash
# =============================================================================
# oak/td.sh — tabular SARSA temporal-difference update on a JSON table
#
# Issue #1329 (oak tick-learner sprint): the factory has no learner — priority
# is a label and a classify bucket list. This is one dumb update: tabular
# SARSA over a JSON weights table, in bash+jq (floats via jq, NOT bash
# arithmetic).
#
# CLI:
#   oak/td.sh WEIGHTS.json UPDATE.json
#
# UPDATE.json is exactly:
#   {"alpha":0.1,"gamma":0.99,"q0":1.0,"x_key":"2|0","a":"idle","r":0,
#    "x2_key":"2|0","a2":"idle"}
# Optional extra key "extra":{"inbound":0} — if present, also updates
# gvf.inbound.V[x_key] with the same SARSA step: cumulant = that number,
# next value = V[x2_key] (missing → 0, never q0).
#
# SARSA, not Q-learning: the purpose target uses the actually-taken next
# action a2, not the max over actions.
#
#   q  = Q[x_key][a]    // q0 if missing
#   q2 = Q[x2_key][a2]  // q0 if missing
#   Q[x_key][a] = q + alpha * (r + gamma * q2 - q)
#
# If WEIGHTS.json is missing it is created as
#   {"q0":1.0,"gvf":{"purpose":{"Q":{}},"inbound":{"V":{}}}}
# (any q0 already set in the file is preserved) and the update is then
# applied. The file is written atomically: <WEIGHTS>.tmp then mv.
#
# Stdout: the new purpose Q value as a JSON number, one line.
# Stderr: diagnostics only.
#
# Does not start organs. Does not read Forgejo. Does not parse pack.toml.
# =============================================================================
set -euo pipefail

log() { echo "td: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") WEIGHTS.json UPDATE.json" >&2
}

[ "$#" -eq 2 ] || { usage; exit 2; }

WEIGHTS_FILE="$1"
UPDATE_FILE="$2"

[ -f "$UPDATE_FILE" ] || { log "update file not found: $UPDATE_FILE"; exit 1; }
jq -e . "$UPDATE_FILE" >/dev/null 2>&1 \
  || { log "update file is not valid JSON: $UPDATE_FILE"; exit 1; }

UPDATE_JSON="$(cat "$UPDATE_FILE")"

# Validate the required shape: numeric alpha/gamma/r, string x/a/x2/a2,
# optional extra.inbound numeric.
jq -e --argjson u "$UPDATE_JSON" '
  (.alpha  | type == "number") and
  (.gamma  | type == "number") and
  (.r      | type == "number") and
  (.x_key  | type == "string") and
  (.a      | type == "string") and
  (.x2_key | type == "string") and
  (.a2     | type == "string") and
  (if .extra == null then true
   else (.extra.inbound | type == "number")
   end)
' >/dev/null 2>&1 \
  || { log "update JSON is missing required keys (alpha,gamma,r,x_key,a,x2_key,a2) or extra.inbound is not a number"; exit 1; }

# Missing weights file → fresh default table (q0 1.0).
if [ -f "$WEIGHTS_FILE" ]; then
  WEIGHTS_JSON="$(cat "$WEIGHTS_FILE")"
else
  log "weights file missing, creating fresh table: $WEIGHTS_FILE"
  WEIGHTS_JSON='{"q0":1.0,"gvf":{"purpose":{"Q":{}},"inbound":{"V":{}}}}'
fi
if ! printf '%s\n' "$WEIGHTS_JSON" | jq -e . >/dev/null 2>&1; then
  log "weights file is not valid JSON: $WEIGHTS_FILE"
  exit 1
fi

# Single-pass update. Defaults resolve in this order:
#   q0  — file's .q0, else update's .q0, else 1.0
#   Q[x][a] — missing → q0
#   V[x]    — missing → 0 (never q0)
# Preserves any other keys already in the weights file.
# shellcheck disable=SC2016  # jq program text, not bash — no expansion wanted
JQ_UPDATE='
  . as $w
  | ($w.q0 // ($u.q0 // 1.0)) as $q0
  | ($w.gvf.purpose.Q // {}) as $Q
  | ((($Q[$u.x_key] // {})[$u.a]) // $q0) as $q
  | ((($Q[$u.x2_key] // {})[$u.a2]) // $q0) as $q2
  | ($q + $u.alpha * ($u.r + $u.gamma * $q2 - $q)) as $newq
  | .gvf.purpose.Q =
      ($Q | .[$u.x_key] = ((($Q[$u.x_key]) // {}) | .[$u.a] = $newq))
  | if $u.extra != null and ($u.extra.inbound != null) then
      ($w.gvf.inbound.V // {}) as $V
      | (($V[$u.x_key]) // 0) as $v
      | (($V[$u.x2_key]) // 0) as $v2
      | .gvf.inbound.V =
          ($V | .[$u.x_key] =
             ($v + $u.alpha * ($u.extra.inbound + $u.gamma * $v2 - $v)))
    else
      .
    end
'

TMP="${WEIGHTS_FILE}.tmp"
mkdir -p "$(dirname "$WEIGHTS_FILE")"
if ! printf '%s\n' "$WEIGHTS_JSON" \
    | jq --argjson u "$UPDATE_JSON" "$JQ_UPDATE" >"$TMP"; then
  rm -f "$TMP"
  log "SARSA update failed"
  exit 1
fi
mv "$TMP" "$WEIGHTS_FILE"

# Stdout: the new purpose Q value, one JSON number, one line.
jq -r --argjson u "$UPDATE_JSON" '.gvf.purpose.Q[$u.x_key][$u.a]' "$WEIGHTS_FILE"
