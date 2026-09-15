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
# Optional key "extra": an object of GVF name → cumulant (a number), e.g.
# {"inbound":0}. Each name's gvf.<name>.V[x_key] is stepped with the same
# SARSA rule: cumulant = that number, next value = V[x2_key] (missing → 0,
# never q0). oak/tick.sh builds the map from the pack's [gvf.<name>] tables
# (#1355); a missing or empty {} extra is a no-op.
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
# optional extra an object of numbers.
# -n: this check uses $u only — no input stream (jq >= 1.7 exits 4 on
# -e with an empty stream, so the program must not read stdin at all).
jq -en --argjson u "$UPDATE_JSON" '
  ($u.alpha  | type == "number") and
  ($u.gamma  | type == "number") and
  ($u.r      | type == "number") and
  ($u.x_key  | type == "string") and
  ($u.a      | type == "string") and
  ($u.x2_key | type == "string") and
  ($u.a2     | type == "string") and
  (if $u.extra == null then true
   elif ($u.extra | type) != "object" then false
   else ($u.extra | to_entries | all(.value | type == "number"))
   end)
' >/dev/null 2>&1 \
  || { log "update JSON is missing required keys (alpha,gamma,r,x_key,a,x2_key,a2) or extra is not an object of numbers"; exit 1; }

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
  # extra GVFs (#1355): each name in the extra map steps its own
  # gvf.<name>.V with the same rule (cumulant extra[<name>], next value
  # V[x2_key], missing → 0, never q0).
  | if ($u.extra // {}) == {} then .
    else
      (def step_gvf($k):
         ($w.gvf[$k].V // {}) as $V
         | (($V[$u.x_key]) // 0) as $v
         | (($V[$u.x2_key]) // 0) as $v2
         | .gvf[$k].V =
             ($V | .[$u.x_key] =
                ($v + $u.alpha * ($u.extra[$k] + $u.gamma * $v2 - $v)));
       reduce ($u.extra | keys_unsorted[]) as $k (.; step_gvf($k)))
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
