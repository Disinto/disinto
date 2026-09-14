#!/usr/bin/env bash
# =============================================================================
# oak/sense.sh — one tick of the oak sensor: pack TOML → state vector x
#
# Issue #1331 (oak tick-learner sprint): the learner needs a REUSED state
# key, not a git tree hash, and the sensor must be a program that reads a
# pack every tick. This is that program: it reads [features.*] from a pack
# TOML, probes each rule, and prints the state vector. Language models never
# write `x` — only this program does.
#
# CLI:
#   oak/sense.sh PACK.toml
#
# Stdout: exactly one line — one JSON object
#   {"x":{...},"key":"..."}
# plus a newline. Diagnostics go to stderr.
#
# Pack dump: python3 -c tomllib only (same pattern as lib/load-project.sh).
#
# Rules (closed):
#   present       1 if `path` exists (relative paths resolve against
#                 $OPS_REPO_ROOT when set and the path is not absolute, else
#                 against the cwd), else 0.
#   integer_file  integer contents of `path`; the key is OMITTED if the file
#                 is missing or not an integer.
#   df_gb         integer free GiB of `path` from `df -BG` (first data line,
#                 field 4, trailing G stripped).
#   http_ok       1 if GET `url` answers 2xx within 2s, else 0.
#   forge_open    count of open issues; the key is omitted when FORGE_API or
#                 FORGE_TOKEN is unset.
#   forge_label   count of open issues carrying `label`; omitted when the
#                 forge API is unset.
#   cmd_running   1 if `pgrep -f pattern` hits, else 0.
#
# Binning: `bins = [5, 20]` → value <5 → 0, <20 → 1, else 2 (in general:
# bin index = number of thresholds the value does not fall below). Bits
# (present, http_ok, cmd_running) carry no bins. A count/df feature WITHOUT
# bins is a pack error: stderr warning, that feature omitted. An unknown
# `rule` omits that feature (no crash).
#
# key: for every feature that produced an x value, its bin index (binned
# features) or its 0/1 bit — features sorted by name, joined with `|`.
#
# sense.sh never writes anything: no weights, no state, no network writes.
#
# Exit codes: 0 = sensed, 1 = bad input (missing/invalid pack), 2 = usage.
# =============================================================================
set -euo pipefail

log() { echo "sense: $*" >&2; }

usage() {
  echo "Usage: $(basename "$0") PACK.toml" >&2;
}

[ "$#" -eq 1 ] || { usage; exit 2; }

PACK_FILE="$1"

command -v python3 >/dev/null 2>&1 || { log "python3 not on PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { log "jq not on PATH"; exit 1; }
[ -f "$PACK_FILE" ] || { log "pack file not found: $PACK_FILE"; exit 1; }

# Pack dump: python3 -c tomllib only (same pattern as lib/load-project.sh).
# Emits one JSON array of feature specs in pack order; only the keys present
# in the feature table are emitted:
#   [{"name":..., "rule":..., "path":..., "url":..., "pattern":...,
#     "label":..., "bins":[...]}]
if ! FEATS_JSON="$(python3 -c '
import json, sys, tomllib

with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)

feats = cfg.get("features", {})
out = []
if isinstance(feats, dict):
    for name, spec in feats.items():
        if not isinstance(spec, dict):
            continue
        s = {"name": name}
        for k in ("rule", "path", "url", "pattern", "label", "bins"):
            if k in spec:
                s[k] = spec[k]
        out.append(s)
print(json.dumps(out))
' "$PACK_FILE")"; then
  log "failed to parse pack TOML: $PACK_FILE"
  exit 1
fi

# resolve_path <p> — a relative path resolves against $OPS_REPO_ROOT when
# set, else against the cwd; an absolute path resolves as-is.
resolve_path() {
  local p="$1"
  case "$p" in
    /*)
      printf '%s' "$p"
      ;;
    *)
      if [ -n "${OPS_REPO_ROOT:-}" ]; then
        printf '%s/%s' "$OPS_REPO_ROOT" "$p"
      else
        printf '%s' "$p"
      fi
      ;;
  esac
}

# bin_index <value> <bins-json> — the bin index: number of thresholds the
# value does not fall below, i.e. thresholds t with t <= value
# (bins [5,20]: 4 → 0, 12 → 1, 20 → 2). Floats via jq, never bash
# arithmetic.
bin_index() {
  jq -n --argjson v "$1" --argjson b "$2" '[$b[] | select(. <= $v)] | length'
}

# forge_issue_count [label] — count open issues via the forge API
# (paginated, 50 per page; `label` restricts to issues carrying it).
# Prints the count; returns 1 on API or JSON failure.
forge_issue_count() {
  local label="${1:-}" page=1 total=0 body n
  while :; do
    body="$(curl -sf -m 10 -H "Authorization: token $FORGE_TOKEN" \
      "${FORGE_API}/issues?state=open&limit=50&page=${page}" 2>/dev/null)" || return 1
    if [ -n "$label" ]; then
      n="$(jq --arg l "$label" \
        '[.[] | select((.labels // []) | map(.name) | index($l))] | length' \
        <<<"$body" 2>/dev/null)" || return 1
    else
      n="$(jq 'length' <<<"$body" 2>/dev/null)" || return 1
    fi
    total=$((total + n))
    if [ "$n" -lt 50 ] || [ "$page" -ge 10 ]; then
      break
    fi
    page=$((page + 1))
  done
  printf '%s' "$total"
}

X_JSON='{}'
KEY_PARTS=()

# add_feature <name> <value> <key-part> — record one x value and its key
# part (bin index or 0/1 bit).
add_feature() {
  local name="$1" v="$2" part="$3"
  X_JSON="$(jq --arg n "$name" --argjson v "$v" '.[$n] = $v' <<<"$X_JSON")"
  KEY_PARTS+=("$name"$'\t'"$part")
}

# need_bins <name> <bins-json> — a count/df feature without bins is a pack
# error: warn on stderr and omit the feature.
need_bins() {
  if [ -z "$2" ]; then
    log "feature $1: count/df rule has no bins — omitting"
    return 1
  fi
  return 0
}

# strip_leading_zeros <int> — normalise "05" → "5" so downstream
# `jq --argjson` never sees a leading-zero literal.
strip_leading_zeros() {
  local sign="" v="$1"
  case "$v" in
    -*)
      sign="-"
      v="${v#-}"
      ;;
  esac
  while [ "${#v}" -gt 1 ] && [[ "$v" == 0* ]]; do
    v="${v#0}"
  done
  printf '%s%s' "$sign" "$v"
}

N="$(jq 'length' <<<"$FEATS_JSON")"
i=0
while [ "$i" -lt "$N" ]; do
  spec="$(jq -c ".[$i]" <<<"$FEATS_JSON")"
  i=$((i + 1))
  name="$(jq -r '.name' <<<"$spec")"
  rule="$(jq -r '.rule // empty' <<<"$spec")"
  bins="$(jq -c '.bins // empty' <<<"$spec")"

  case "$rule" in
    present)
      p="$(jq -r '.path // empty' <<<"$spec")"
      if [ -z "$p" ]; then
        log "feature $name: present without path — omitting"
        continue
      fi
      if [ -e "$(resolve_path "$p")" ]; then v=1; else v=0; fi
      add_feature "$name" "$v" "$v"
      ;;
    integer_file)
      p="$(jq -r '.path // empty' <<<"$spec")"
      v=""
      if [ -n "$p" ] && [ -f "$(resolve_path "$p")" ]; then
        raw="$(tr -d '[:space:]' <"$(resolve_path "$p")" 2>/dev/null)" || raw=""
        if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
          v="$(strip_leading_zeros "$raw")"
        fi
      fi
      [ -n "$v" ] || continue
      need_bins "$name" "$bins" || continue
      add_feature "$name" "$v" "$(bin_index "$v" "$bins")"
      ;;
    df_gb)
      p="$(jq -r '.path // empty' <<<"$spec")"
      v=""
      if [ -n "$p" ]; then
        v="$(df -BG "$p" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
        v="${v%G}"
        [[ "$v" =~ ^[0-9]+$ ]] || v=""
      fi
      [ -n "$v" ] || continue
      need_bins "$name" "$bins" || continue
      add_feature "$name" "$v" "$(bin_index "$v" "$bins")"
      ;;
    http_ok)
      u="$(jq -r '.url // empty' <<<"$spec")"
      v=0
      if [ -n "$u" ]; then
        code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' -- "$u" 2>/dev/null || true)"
        case "$code" in
          2[0-9][0-9]) v=1 ;;
        esac
      fi
      add_feature "$name" "$v" "$v"
      ;;
    forge_open)
      if [ -z "${FORGE_API:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
        log "forge API unset (FORGE_API/FORGE_TOKEN) — omitting $name"
        continue
      fi
      v="$(forge_issue_count)" || continue
      need_bins "$name" "$bins" || continue
      add_feature "$name" "$v" "$(bin_index "$v" "$bins")"
      ;;
    forge_label)
      if [ -z "${FORGE_API:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
        log "forge API unset (FORGE_API/FORGE_TOKEN) — omitting $name"
        continue
      fi
      label="$(jq -r '.label // empty' <<<"$spec")"
      if [ -z "$label" ]; then
        log "feature $name: forge_label without label — omitting"
        continue
      fi
      v="$(forge_issue_count "$label")" || continue
      need_bins "$name" "$bins" || continue
      add_feature "$name" "$v" "$(bin_index "$v" "$bins")"
      ;;
    cmd_running)
      pat="$(jq -r '.pattern // empty' <<<"$spec")"
      v=0
      if [ -n "$pat" ] && pgrep -f "$pat" >/dev/null 2>&1; then
        v=1
      fi
      add_feature "$name" "$v" "$v"
      ;;
    *)
      if [ -n "$rule" ]; then
        log "feature $name: unknown rule '$rule' — omitting"
      else
        log "feature $name: no rule — omitting"
      fi
      continue
      ;;
  esac
done

# key: features sorted by name, key parts joined with `|`. The tab separator
# sorts below any feature-name byte, so a whole-line sort sorts by name.
KEY=""
if [ "${#KEY_PARTS[@]}" -gt 0 ]; then
  KEY="$(printf '%s\n' "${KEY_PARTS[@]}" | LC_ALL=C sort \
    | awk -F'\t' 'NR > 1 {printf "|"} {printf "%s", $2}')"
fi

# Stdout: exactly one line — one JSON object plus a newline.
jq -cn --argjson x "$X_JSON" --arg k "$KEY" '{x: $x, key: $k}'
