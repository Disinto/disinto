#!/usr/bin/env bash
# =============================================================================
# evaluate-recipes.sh — Evaluate abnormal-signal recipes against preflight output
#
# Reads supervisor/recipes.yaml and a preflight output file, then outputs JSON
# to stdout listing which recipes fired.
#
# Usage:
#   bash supervisor/evaluate-recipes.sh <(bash supervisor/preflight.sh /opt/disinto/projects/disinto.toml)
#   bash supervisor/evaluate-recipes.sh /path/to/preflight-output.txt
#
# Output (JSON):
#   {"fired":[{"name":"disk-pressure","severity":"P1","evidence":"Disk: 85% used","action":"direct","action_script":"..."}]}
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"
RECIPE_FILE="${1:-$FACTORY_ROOT/supervisor/recipes.yaml}"
PREFLIGHT_FILE="${2:-}"

if [ -z "$PREFLIGHT_FILE" ]; then
  echo "Usage: $0 <recipes.yaml> <preflight-output-file-or-pipe>" >&2
  exit 1
fi

# ── Extract a section from preflight text ──────────────────────────────────
# Given a section name (e.g. "System Resources"), returns lines between
# "## Section Name" and the next "## " header (or EOF).
extract_section() {
  local section="$1"
  local preflight_text="$2"
  local in_section=false

  while IFS= read -r line; do
    # Match "## Section" or "## Section (...)" — prefix match on section name
    if [[ "$line" == "## ${section}" || "$line" == "## ${section}(" || "$line" == "## ${section} (" ]]; then
      in_section=true
      continue
    fi
    if $in_section; then
      if [[ "$line" == "## "* ]]; then
        break
      fi
      printf '%s\n' "$line"
    fi
  done <<< "$preflight_text"
}

# ── Rule evaluators ────────────────────────────────────────────────────────
# Each returns 0 (rule fires) or 1 (rule does not fire).
# Sets _EVIDENCE var on match.

eval_ram_available_mb_lt() {
  local section_text="$1"
  local threshold="$2"
  local ram_mb
  ram_mb=$(printf '%s\n' "$section_text" | grep -oP 'RAM:\s+\K[0-9]+' | head -1)
  if [ -n "${ram_mb:-}" ] && [ "$ram_mb" -lt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="RAM: ${ram_mb}MB available (threshold: ${threshold}MB)"
    return 0
  fi
  return 1
}

eval_swap_mb_gt() {
  local section_text="$1"
  local threshold="$2"
  local swap_mb
  swap_mb=$(printf '%s\n' "$section_text" | grep -oP 'Swap:\s+\K[0-9]+' | head -1)
  if [ -n "${swap_mb:-}" ] && [ "$swap_mb" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="Swap: ${swap_mb}MB used (threshold: ${threshold}MB)"
    return 0
  fi
  return 1
}

eval_disk_pct_gt() {
  local section_text="$1"
  local threshold="$2"
  local disk_pct
  disk_pct=$(printf '%s\n' "$section_text" | grep -oP 'Disk:\s+\K[0-9]+' | head -1)
  if [ -n "${disk_pct:-}" ] && [ "$disk_pct" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="Disk: ${disk_pct}% used (threshold: ${threshold}%)"
    return 0
  fi
  return 1
}

eval_field_eq() {
  local section_text="$1"
  local field="$2"
  local expected="$3"
  local actual
  # Extract value after "Field: " or "Field <whitespace> Value"
  actual=$(printf '%s\n' "$section_text" | grep -i "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" || true)
  if [ "$actual" = "$expected" ]; then
    _EVIDENCE="${field}: ${actual}"
    return 0
  fi
  return 1
}

eval_stuck_gt() {
  local section_text="$1"
  local threshold="$2"
  local stuck
  stuck=$(printf '%s\n' "$section_text" | grep -oP 'Stuck\s*\(\K[0-9]+' | head -1)
  if [ -n "${stuck:-}" ] && [ "$stuck" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="CI pipelines stuck: ${stuck} (threshold: >${threshold})"
    return 0
  fi
  return 1
}

eval_pending_gt() {
  local section_text="$1"
  local threshold="$2"
  local pending
  pending=$(printf '%s\n' "$section_text" | grep -oP 'Pending\s*\(\K[0-9]+' | head -1)
  if [ -n "${pending:-}" ] && [ "$pending" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="CI pipelines pending: ${pending} (threshold: >${threshold})"
    return 0
  fi
  return 1
}

eval_any_older_than_min() {
  local section_text="$1"
  local threshold="$2"
  local oldest=0
  local oldest_name=""

  while IFS= read -r line; do
    local age name
    name=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | sed 's/:.*//' | tr -d ' ')
    age=$(printf '%s' "$line" | grep -oP '[0-9]+(?=min old)' | head -1)
    if [ -n "${age:-}" ] && [ "$age" -gt "$oldest" ] 2>/dev/null; then
      oldest=$age
      oldest_name="$name"
    fi
  done <<< "$section_text"

  if [ "$oldest" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="Stale worktree: ${oldest_name} (${oldest}min old, threshold: >${threshold}min)"
    return 0
  fi
  return 1
}

eval_dead_lock_gt() {
  local section_text="$1"
  local threshold="$2"
  local dead_count=0

  while IFS= read -r line; do
    if [[ "$line" == *"dead"* ]]; then
      dead_count=$((dead_count + 1))
    fi
  done <<< "$section_text"

  if [ "$dead_count" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="Dead lock files: ${dead_count} (threshold: >${threshold})"
    return 0
  fi
  return 1
}

eval_stale_prs_gt() {
  local section_text="$1"
  local threshold="$2"
  # Count PR lines (start with #)
  local pr_count
  pr_count=$(printf '%s\n' "$section_text" | grep -cP '^#\d+' || true)
  if [ "${pr_count:-0}" -gt "$threshold" ] 2>/dev/null; then
    _EVIDENCE="Open PRs: ${pr_count} (threshold: >${threshold})"
    return 0
  fi
  return 1
}

# ── Main logic ─────────────────────────────────────────────────────────────

# Read preflight text once
PREFLIGHT_TEXT=""
if [ -f "$PREFLIGHT_FILE" ]; then
  PREFLIGHT_TEXT="$(cat "$PREFLIGHT_FILE")"
elif [ -p "$PREFLIGHT_FILE" ] || [ -t 0 ]; then
  # stdin or pipe — read it
  PREFLIGHT_TEXT="$(cat)"
fi

# Count recipes
recipe_count=$(yq eval '.recipes | length' "$RECIPE_FILE")

# Build fired array
fired_json="[]"

for ((i = 0; i < recipe_count; i++)); do
  name=$(yq eval ".recipes[$i].name" "$RECIPE_FILE")
  severity=$(yq eval ".recipes[$i].severity" "$RECIPE_FILE")
  detect_section=$(yq eval ".recipes[$i].detect.section" "$RECIPE_FILE")
  detect_rule=$(yq eval ".recipes[$i].detect.rule" "$RECIPE_FILE")
  detect_threshold=$(yq eval ".recipes[$i].detect.threshold // \"__MISSING__\"" "$RECIPE_FILE")
  detect_field=$(yq eval ".recipes[$i].detect.field // \"__MISSING__\"" "$RECIPE_FILE")
  detect_value=$(yq eval ".recipes[$i].detect.value // \"__MISSING__\"" "$RECIPE_FILE")
  action=$(yq eval ".recipes[$i].action" "$RECIPE_FILE")
  action_script=$(yq eval ".recipes[$i].action_script // \"__MISSING__\"" "$RECIPE_FILE")

  # Extract the relevant section from preflight output
  section_text=$(extract_section "$detect_section" "$PREFLIGHT_TEXT")

  # Evaluate the rule
  _EVIDENCE=""
  _fired=false
  case "$detect_rule" in
    ram_available_mb_lt)
      eval_ram_available_mb_lt "$section_text" "$detect_threshold" && _fired=true ;;
    swap_mb_gt)
      eval_swap_mb_gt "$section_text" "$detect_threshold" && _fired=true ;;
    disk_pct_gt)
      eval_disk_pct_gt "$section_text" "$detect_threshold" && _fired=true ;;
    field_eq)
      eval_field_eq "$section_text" "$detect_field" "$detect_value" && _fired=true ;;
    stuck_gt)
      eval_stuck_gt "$section_text" "$detect_threshold" && _fired=true ;;
    pending_gt)
      eval_pending_gt "$section_text" "$detect_threshold" && _fired=true ;;
    any_older_than_min)
      eval_any_older_than_min "$section_text" "$detect_threshold" && _fired=true ;;
    dead_lock_gt)
      eval_dead_lock_gt "$section_text" "$detect_threshold" && _fired=true ;;
    stale_prs_gt)
      eval_stale_prs_gt "$section_text" "$detect_threshold" && _fired=true ;;
    *)
      echo "WARNING: unknown rule '$detect_rule' for recipe '$name'" >&2
      continue ;;
  esac

  if $_fired; then
    entry=$(jq -n \
      --arg name "$name" \
      --arg severity "$severity" \
      --arg evidence "$_EVIDENCE" \
      --arg action "$action" \
      --arg action_script "$action_script" \
      '{name: $name, severity: $severity, evidence: $evidence, action: $action, action_script: $action_script}')

    fired_json=$(printf '%s' "$fired_json" | jq --argjson entry "$entry" '. + [$entry]')
  fi
done

# Output final JSON
jq -n --argjson fired "$fired_json" '{fired: $fired}'
