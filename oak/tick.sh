#!/usr/bin/env bash
# =============================================================================
# oak/tick.sh — one tick of the oak tick-learner: sense → critic → pick → td
#               → start at most one organ
#
# Issue #1332 (oak tick-learner sprint): the pieces exist (oak/sense.sh,
# oak/pick.sh, oak/td.sh) but nothing drives them. This is the driver: one
# tick records one transition, applies one SARSA update, and starts at most
# one organ. #1333 wires this into the entrypoint loop; this file is the
# unit and is self-contained (no entrypoint changes here).
#
# CLI:
#   oak/tick.sh projects/<name>.toml
#
#   The toml is passed through to any organ this tick starts.
#
# One tick:
#   1. sense  — oak/sense.sh PACK → state vector x + reused state key
#   2. critic — r for x: pack [critic] builtin "present" → r=1 iff
#               x[feature] is non-zero; no [critic] → r=0
#   3. legal  — pack [actions.*] names; idle is always legal (see below)
#   4. pick   — oak/pick.sh (ε-greedy, pack [learn].epsilon)
#   5. td     — when a previous tick exists (last.json): oak/td.sh with the
#               SARSA step (last.x_key, last.a, r, this key, the action
#               just picked) — pick FIRST, update second: this is SARSA,
#               a2 is the action actually taken
#   6. state  — last.json := {x_key, a, x} (atomic tmp+mv); append one
#               transition line to transitions.jsonl — only when a
#               previous tick existed. The first tick is a boot: it writes
#               last.json and nothing else.
#   7. start  — unless OAK_DRY_RUN=1 and the action is not idle: start
#               `bash "$FACTORY_ROOT/<script>" "<toml>"` in the background,
#               logging to $DISINTO_LOG_DIR/<action>.log. Never starts
#               `dispatch` (AD-006: external actions go through vault
#               dispatch). Never commits to git. Never waits for the organ.
#
# State lives in the ops repo, $OPS_REPO_ROOT/oak/:
#   weights.json      — oak weights table (oak/td.sh schema)
#   transitions.jsonl — one line per learned transition
#   last.json         — the previous tick {x_key, a, x}
# Pack: $OPS_REPO_ROOT/pack.toml if present, else the factory's
# $FACTORY_ROOT/oak/pack.example.toml (read-only fallback — the tick never
# copies it over the ops side).
#
# Legal list rules (closed):
#   * idle is always legal.
#   * an organ with a non-empty script is dropped when `pgrep -f` already
#     matches that script's basename (one running instance per organ).
#     Note: pgrep -f scans the FULL command line, so any process whose argv
#     merely quotes the script name (a test/CI wrapper) also drops the
#     organ for that tick — keep organ script names distinctive.
#   * dispatch is legal only in an automatic-mode vault under
#     max_in_flight: it is dropped when vault.mode != "automatic" (a
#     missing [vault] has no mode → always dropped) or when
#     x.vault_in_flight >= max_in_flight (a missing max_in_flight means
#     0 → always dropped). The tick never execs dispatch anyway (AD-006).
#   * when AGENT_ROLES is set, each organ must map to a role in it
#     (review-poll→review, dev-poll→dev, gardener-step→gardener,
#     architect-run→architect, planner-run→planner,
#     predictor-run→predictor, supervisor-run→supervisor); actions with no
#     mapping are dropped. dispatch needs no role — the vault gate above
#     governs it.
#
# Stdout: the chosen action, one line — in every mode. Diagnostics go to
# stderr. Exit 0 = ticked, 1 = bad state (no pack, sense/pick/td failed),
# 2 = usage error.
# =============================================================================
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") PROJECT.toml" >&2
}
[ "$#" -eq 1 ] || { usage; exit 2; }

PROJECT_TOML="$1"
FACTORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Shared environment (FACTORY_ROOT, DISINTO_LOG_DIR, log helpers, project
# vars via load-project.sh). Mirrors the organ bootstrap pattern
# (dev/dev-poll.sh): PROJECT_TOML exported before sourcing.
export PROJECT_TOML
# shellcheck source=../lib/env.sh
source "$FACTORY_ROOT/lib/env.sh"

LOG_AGENT="oak"
# Diagnostics go to stderr — stdout is the chosen action and nothing else.
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LOG_AGENT" "$*" >&2
}

[ -n "${OPS_REPO_ROOT:-}" ] || {
  log "OPS_REPO_ROOT must be set (entrypoint or the project TOML)"
  exit 1
}

OAK_DIR="$OPS_REPO_ROOT/oak"
WEIGHTS_FILE="$OAK_DIR/weights.json"
TRANSITIONS_FILE="$OAK_DIR/transitions.jsonl"
LAST_FILE="$OAK_DIR/last.json"
mkdir -p "$OAK_DIR"

# Pack: the ops repo's own pack wins; the factory's example is the
# read-only fallback.
if [ -f "$OPS_REPO_ROOT/pack.toml" ]; then
  PACK_FILE="$OPS_REPO_ROOT/pack.toml"
else
  PACK_FILE="$FACTORY_ROOT/oak/pack.example.toml"
fi
[ -f "$PACK_FILE" ] || {
  log "no pack: tried $OPS_REPO_ROOT/pack.toml and $PACK_FILE"
  exit 1
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ── pack: [learn] / [critic] / [vault] / [actions.*] ────────────────────────
# python3 tomllib dump (same pattern as oak/sense.sh), with type validation:
# a malformed pack fails the tick, it never learns from a broken config.
if ! PACK_JSON="$(python3 -c '
import json, sys, tomllib

path = sys.argv[1]
try:
    with open(path, "rb") as f:
        cfg = tomllib.load(f)
except Exception as exc:
    sys.stderr.write("tick: cannot parse pack %s: %s\n" % (path, exc))
    sys.exit(1)

def fail(msg):
    sys.stderr.write("tick: %s\n" % msg)
    sys.exit(1)

def num(table, key, default, ctx):
    v = table.get(key, default)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        fail(ctx + " " + key + " must be a number, got " + repr(v))
    return float(v)

learn = cfg.get("learn", {})
if not isinstance(learn, dict):
    fail("[learn] must be a table")
L = {
    "alpha": num(learn, "alpha", 0.1, "[learn]"),
    "gamma": num(learn, "gamma", 0.99, "[learn]"),
    "epsilon": num(learn, "epsilon", 0.1, "[learn]"),
    "q0": num(learn, "q0", 1.0, "[learn]"),
}

critic = cfg.get("critic")
C = None
if critic is not None:
    if not isinstance(critic, dict):
        fail("[critic] must be a table")
    b = critic.get("builtin")
    ft = critic.get("feature")
    if b is not None and not isinstance(b, str):
        fail("[critic] builtin must be a string")
    if ft is not None and not isinstance(ft, str):
        fail("[critic] feature must be a string")
    C = {"builtin": b, "feature": ft}

vault = cfg.get("vault")
V = None
if vault is not None:
    if not isinstance(vault, dict):
        fail("[vault] must be a table")
    m = vault.get("mode")
    mif = vault.get("max_in_flight")
    if m is not None and not isinstance(m, str):
        fail("[vault] mode must be a string")
    if mif is not None and (isinstance(mif, bool) or not isinstance(mif, int)):
        fail("[vault] max_in_flight must be an integer")
    V = {"mode": m, "max_in_flight": mif}

actions = cfg.get("actions", {})
if not isinstance(actions, dict):
    fail("[actions] must be a table")
A = {}
for name, spec in actions.items():
    if isinstance(spec, dict):
        s = spec.get("script", "")
    elif isinstance(spec, str):
        s = spec
    else:
        fail("[actions." + str(name) + "] must be a table or a string")
    if not isinstance(s, str):
        fail("[actions." + str(name) + "] script must be a string")
    A[name] = s

print(json.dumps({"learn": L, "critic": C, "vault": V, "actions": A}))
' "$PACK_FILE")"; then
  log "failed to parse pack: $PACK_FILE"
  exit 1
fi

ALPHA="$(jq '.learn.alpha' <<<"$PACK_JSON")"
GAMMA="$(jq '.learn.gamma' <<<"$PACK_JSON")"
EPSILON="$(jq '.learn.epsilon' <<<"$PACK_JSON")"
Q0="$(jq '.learn.q0' <<<"$PACK_JSON")"

ACTIONS_JSON="$(jq -c '.actions' <<<"$PACK_JSON")"

VAULT_JSON="$(jq -c '.vault // null' <<<"$PACK_JSON")"
VAULT_MODE=""
VAULT_MAX_IF=0
if [ "$VAULT_JSON" != "null" ]; then
  VAULT_MODE="$(jq -r '.mode // empty' <<<"$VAULT_JSON")"
  VAULT_MAX_IF="$(jq -r '.max_in_flight // empty' <<<"$VAULT_JSON")"
fi
# Missing [vault] (or a missing max_in_flight) means zero capacity: the
# capacity check below then always drops dispatch (0 >= 0) — the documented
# default, so dispatch can never be legal-but-never-startable.
VAULT_MAX_IF="${VAULT_MAX_IF:-0}"

# ── 1. sense ────────────────────────────────────────────────────────────────
if ! SENSE_OUT="$(bash "$FACTORY_ROOT/oak/sense.sh" "$PACK_FILE")"; then
  log "sense failed: $PACK_FILE"
  exit 1
fi
X_JSON="$(jq -c '.x' <<<"$SENSE_OUT")"
KEY="$(jq -r '.key' <<<"$SENSE_OUT")"

# ── 2. critic ───────────────────────────────────────────────────────────────
CRITIC_JSON="$(jq -c '.critic // null' <<<"$PACK_JSON")"
R=0
if [ "$CRITIC_JSON" != "null" ]; then
  BUILTIN="$(jq -r '.builtin // empty' <<<"$CRITIC_JSON")"
  CFEATURE="$(jq -r '.feature // empty' <<<"$CRITIC_JSON")"
  case "$BUILTIN" in
    present)
      XV="$(jq -r --arg f "$CFEATURE" '.[$f] // empty' <<<"$X_JSON")"
      if [ -n "$XV" ] && [ "$XV" != "0" ]; then
        R=1
      fi
      ;;
    "")
      log "critic: no builtin — r=0"
      ;;
    *)
      log "critic: unknown builtin '$BUILTIN' — r=0"
      ;;
  esac
fi

# ── 3. legal ────────────────────────────────────────────────────────────────
# idle first (it is always legal), then the pack's actions in pack order.
add_legal() {
  local n="$1" e
  if [ "${#LEGAL[@]}" -gt 0 ]; then
    for e in "${LEGAL[@]}"; do
      [ "$e" = "$n" ] && return 0
    done
  fi
  LEGAL+=("$n")
}
LEGAL=()
add_legal "idle"
while IFS= read -r n; do
  add_legal "$n"
done < <(jq -r 'keys_unsorted[]' <<<"$ACTIONS_JSON")

FINAL_LEGAL=()
for a in "${LEGAL[@]}"; do
  if [ "$a" != "idle" ]; then
    # One running instance per organ.
    SCRIPT="$(jq -r --arg a "$a" '.[$a] // empty' <<<"$ACTIONS_JSON")"
    if [ -n "$SCRIPT" ]; then
      BASE="${SCRIPT##*/}"
      if pgrep -f "$BASE" >/dev/null 2>&1; then
        log "dropping $a: $BASE already running"
        continue
      fi
    fi
    # Vault gate: dispatch is legal only in an automatic-mode vault, under
    # max_in_flight. A missing [vault] (no mode) therefore drops it — it must
    # never be legal-but-never-startable (the tick never execs dispatch,
    # AD-006). A missing max_in_flight means 0 → over capacity → dropped.
    if [ "$a" = "dispatch" ]; then
      if [ "$VAULT_MODE" != "automatic" ]; then
        log "dropping dispatch: vault.mode is not automatic (mode='${VAULT_MODE:-<none>}')"
        continue
      fi
      FLIGHT="$(jq -r '.vault_in_flight // empty' <<<"$X_JSON")"
      [ -n "$FLIGHT" ] || FLIGHT=0
      if jq -en --argjson f "$FLIGHT" --argjson m "$VAULT_MAX_IF" '$f >= $m' >/dev/null; then
        log "dropping dispatch: vault_in_flight $FLIGHT >= max_in_flight $VAULT_MAX_IF"
        continue
      fi
    fi
    # AGENT_ROLES: each organ must map to a role that is active. (dispatch
    # needs no role: it reaches here only if it already passed the vault
    # gate above, i.e. an automatic vault under capacity.)
    if [ -n "${AGENT_ROLES:-}" ] && [ "$a" != "dispatch" ]; then
      case "$a" in
        review-poll) ROLE="review" ;;
        dev-poll) ROLE="dev" ;;
        gardener-step) ROLE="gardener" ;;
        architect-run) ROLE="architect" ;;
        planner-run) ROLE="planner" ;;
        predictor-run) ROLE="predictor" ;;
        supervisor-run) ROLE="supervisor" ;;
        *)
          log "dropping $a: no role mapping under AGENT_ROLES"
          continue
          ;;
      esac
      case ",${AGENT_ROLES}," in
        *",$ROLE,"*) : ;;
        *)
          log "dropping $a: role '$ROLE' not in AGENT_ROLES"
          continue
          ;;
      esac
    fi
  fi
  FINAL_LEGAL+=("$a")
done

# ── 4. pick ─────────────────────────────────────────────────────────────────
LEGAL_FILE="$TMPD/legal.json"
{
  printf '%s\n' "${FINAL_LEGAL[@]}"
} | jq -R . | jq -cs --arg xk "$KEY" --argjson e "$EPSILON" --argjson q0 "$Q0" \
  '{x_key: $xk, epsilon: $e, q0: $q0, legal: .}' >"$LEGAL_FILE"

if ! ACTION="$(bash "$FACTORY_ROOT/oak/pick.sh" "$WEIGHTS_FILE" "$LEGAL_FILE")"; then
  log "pick failed"
  exit 1
fi
[ -n "$ACTION" ] || { log "pick returned no action"; exit 1; }

# ── 5+6. td + state (SARSA: a2 is the action just picked) ──────────────────
LAST_JSON=""
if [ -f "$LAST_FILE" ]; then
  if ! LAST_JSON="$(jq -c . "$LAST_FILE" 2>/dev/null)"; then
    log "last.json is not valid JSON — ignoring it: $LAST_FILE"
    LAST_JSON=""
  fi
fi
HAS_LAST=0
LAST_X_KEY=""
LAST_A=""
LAST_X='{}'
if [ -n "$LAST_JSON" ]; then
  LAST_X_KEY="$(jq -r '.x_key // empty' <<<"$LAST_JSON")"
  LAST_A="$(jq -r '.a // empty' <<<"$LAST_JSON")"
  LAST_X="$(jq -c '.x // {}' <<<"$LAST_JSON")"
  if [ -n "$LAST_X_KEY" ] && [ -n "$LAST_A" ]; then
    HAS_LAST=1
  else
    log "last.json missing x_key/a — ignoring it: $LAST_FILE"
  fi
fi

if [ "$HAS_LAST" -eq 1 ]; then
  UPDATE_FILE="$TMPD/update.json"
  jq -cn \
    --argjson alpha "$ALPHA" \
    --argjson gamma "$GAMMA" \
    --argjson q0 "$Q0" \
    --arg xk "$LAST_X_KEY" \
    --arg a "$LAST_A" \
    --argjson r "$R" \
    --arg x2k "$KEY" \
    --arg a2 "$ACTION" \
    '{alpha:$alpha, gamma:$gamma, q0:$q0, x_key:$xk, a:$a, r:$r, x2_key:$x2k, a2:$a2}' \
    >"$UPDATE_FILE"
  if ! NEWQ="$(bash "$FACTORY_ROOT/oak/td.sh" "$WEIGHTS_FILE" "$UPDATE_FILE")"; then
    log "td failed"
    exit 1
  fi
  log "Q[$LAST_X_KEY][$LAST_A] -> $NEWQ"

  # One line per learned transition: x/a are the PREVIOUS tick's (read from
  # last.json before the overwrite below), x2/r are this tick's.
  jq -cn \
    --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson x "$LAST_X" \
    --arg a "$LAST_A" \
    --argjson r "$R" \
    --argjson x2 "$X_JSON" \
    '{t:$t, x:$x, a:$a, r:$r, x2:$x2}' >>"$TRANSITIONS_FILE"
fi

# last.json: this tick becomes the previous tick (atomic tmp+mv).
# Assumes ONE sequential tick loop (#1333). A fixed .tmp name is safe under a
# single writer; two concurrent ticks would race this overwrite and the
# transition append above — serialize them (or flock $OAK_DIR/.lock) before
# ever parallelizing ticks.
jq -cn --arg xk "$KEY" --arg a "$ACTION" --argjson x "$X_JSON" \
  '{x_key:$xk, a:$a, x:$x}' >"$LAST_FILE.tmp"
mv "$LAST_FILE.tmp" "$LAST_FILE"

# ── 7. start ────────────────────────────────────────────────────────────────
if [ "${OAK_DRY_RUN:-}" = "1" ]; then
  log "OAK_DRY_RUN=1 — not starting $ACTION"
elif [ "$ACTION" = "idle" ]; then
  :
else
  SCRIPT="$(jq -r --arg a "$ACTION" '.[$a] // empty' <<<"$ACTIONS_JSON")"
  if [ "$ACTION" = "dispatch" ]; then
    log "dispatch picked — never started by tick (#1332; the vault's job, AD-006)"
  elif [ -n "$SCRIPT" ]; then
    mkdir -p "$DISINTO_LOG_DIR"
    log "starting $ACTION → $DISINTO_LOG_DIR/$ACTION.log"
    bash "$FACTORY_ROOT/$SCRIPT" "$PROJECT_TOML" >>"$DISINTO_LOG_DIR/$ACTION.log" 2>&1 &
    log "started $ACTION (pid $!)"
  else
    log "action $ACTION has no script — not starting"
  fi
fi

# Stdout: the chosen action, one line, nothing else.
printf '%s\n' "$ACTION"
