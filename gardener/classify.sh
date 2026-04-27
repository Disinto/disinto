#!/usr/bin/env bash
# =============================================================================
# gardener/classify.sh — Bash-only task classifier (priority-ordered)
#
# Scans all open issues and emits one highest-priority undone task to stdout.
# Pure bash + curl + jq — no model calls. Keeps detection cheap and
# deterministic.
#
# Priority (top to bottom):
#   1. blocker-starving-the-factory — non-backlog dep of a backlog issue
#   2. enrich-underspecified       — labeled underspecified with enough signal
#   3. enrich-bug-report           — open unlabeled bug with reproduction steps
#   4. promote-tech-debt           — tech-debt issue passing heuristic
#   5. bundle-dust                 — dust group with >= 3 distinct issues
#   6. agents-md-stale             — AGENTS.md watermark predates git log head
#   7. pitch-vision                — open vision issue with no architect pitch
#
# Usage:
#   gardener/classify.sh [projects/disinto.toml]
#
# Output:
#   One JSON line on stdout: {"task":"<bucket>","issue":<num>,"ctx":{...}}
#   Or empty stdout (CLEAN signal) if nothing actionable.
#
# Environment:
#   Reads FORGE_API and FORGE_TOKEN from environment (matches existing scripts).
#   If a TOML path is given, sources lib/load-project.sh for derived vars.
#
# Exit:
#   0 on success (including CLEAN), non-zero only on infrastructure failure.
# =============================================================================
set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

# Accept project config from argument; default to disinto
PROJECT_TOML="${1:-}"

# ── Environment ──────────────────────────────────────────────────────────────
if [ -n "$PROJECT_TOML" ] && [ -f "$PROJECT_TOML" ]; then
  export PROJECT_TOML
  source "${FACTORY_ROOT}/lib/env.sh"
fi

: "${FORGE_API:?must set FORGE_API (or pass a project TOML)}"
: "${FORGE_TOKEN:?must set FORGE_TOKEN}"

# ── Constants ────────────────────────────────────────────────────────────────
DUST_FILE="${FACTORY_ROOT}/gardener/dust.jsonl"
AGENTS_MD="${FACTORY_ROOT}/AGENTS.md"
OPS_REPO_ROOT="${OPS_REPO_ROOT:-}"

# ── Helpers ──────────────────────────────────────────────────────────────────
# Shared pagination helper (avoids duplication with lib/env.sh).
# shellcheck source=lib/forge-paginate.sh
source "${FACTORY_ROOT}/lib/forge-paginate.sh"

# Fetch all open issues via forge_api_all (shared pagination from lib/forge-paginate.sh).
fetch_open_issues() {
  forge_api_all "/issues?state=open"
}

# Extract dependency issue numbers from an issue body (inline with parse-deps.sh).
extract_deps() {
  local body="$1"
  printf '%s' "$body" | awk '
    BEGIN { IGNORECASE=1; capture=0 }
    /^##? *(Depends on|Blocked by|Dependencies)/ { capture=1; next }
    capture && /^##? / { capture=0 }
    capture { print }
  ' | grep -oP '#\K[0-9]+' || true
}

# ── Priority bucket checks ──────────────────────────────────────────────────

# 1. blocker-starving-the-factory
#    Find non-backlog issues that are dependencies of backlog issues.
check_blocker_starving() {
  local issues_json="$1"
  local backlog_ids non_backlog_ids best_num="" best_time=""

  # Collect IDs and bodies of backlog issues
  backlog_ids=$(printf '%s' "$issues_json" | jq -r '[.[] | select(.labels | any(.name == "backlog")) | .number] | .[]' 2>/dev/null) || backlog_ids=""
  if [ -z "$backlog_ids" ]; then
    return 0
  fi

  # Collect non-backlog issue IDs
  non_backlog_ids=$(printf '%s' "$issues_json" | jq -r '[.[] | select(.labels | map(.name) | all(. != "backlog")) | .number] | .[]' 2>/dev/null) || non_backlog_ids=""
  if [ -z "$non_backlog_ids" ]; then
    return 0
  fi

  # For each backlog issue, check its deps against non-backlog set
  while IFS= read -r bid; do
    [ -z "$bid" ] && continue
    # Get the body for this backlog issue
    local bbody
    bbody=$(printf '%s' "$issues_json" | jq -r --argjson n "$bid" \
      '.[] | select(.number == $n) | .body // ""')

    # Extract dependency numbers
    local deps
    deps=$(extract_deps "$bbody")
    [ -z "$deps" ] && continue

    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      # Check if this dep is a non-backlog issue
      if printf '%s\n' "$non_backlog_ids" | grep -qx "$dep"; then
        # Get the dep issue's updated_at timestamp
        local dep_ts
        dep_ts=$(printf '%s' "$issues_json" | jq -r --argjson n "$dep" \
          '.[] | select(.number == $n) | .updated_at' 2>/dev/null) || continue
        if [ -z "$best_time" ] || [[ "$dep_ts" > "$best_time" ]]; then
          best_num="$dep"
          best_time="$dep_ts"
        fi
      fi
    done <<< "$deps"
  done <<< "$backlog_ids"

  if [ -n "$best_num" ]; then
    local ctx
    ctx=$(printf '%s' "$issues_json" | jq -c --argjson n "$best_num" \
      '.[] | select(.number == $n) | {title, updated_at}')
    printf '{"task":"blocker-starving-the-factory","issue":%s,"ctx":%s}\n' \
      "$best_num" "$ctx"
    return 0
  fi
  return 0
}

# 2. enrich-underspecified
#    Issue labeled underspecified (or has had backlog stripped) with body
#    containing enough signal to enrich (>= 100 chars of non-whitespace).
check_enrich_underspecified() {
  local issues_json="$1"
  local best_num="" best_ts=""

  local candidates
  candidates=$(printf '%s' "$issues_json" | jq -c '
    [.[] | select(.labels | any(.name == "underspecified"))]
  ' 2>/dev/null) || candidates="[]"

  local count
  count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  for i in $(seq 0 $((count - 1))); do
    local num ts body
    num=$(printf '%s' "$candidates" | jq -r ".[$i].number")
    ts=$(printf '%s' "$candidates" | jq -r ".[$i].updated_at")
    body=$(printf '%s' "$candidates" | jq -r ".[$i].body // \"\"")

    # Check body has enough signal (>= 100 non-whitespace chars)
    local signal
    signal=$(printf '%s' "$body" | tr -d '[:space:]' | wc -c)
    if [ "${signal:-0}" -lt 100 ]; then
      continue
    fi

    # Most recently updated wins
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best_num="$num"
      best_ts="$ts"
    fi
  done

  if [ -n "$best_num" ]; then
    local ctx
    ctx=$(printf '%s' "$candidates" | jq -c ".[] | select(.number == $best_num) | {title, updated_at}")
    printf '{"task":"enrich-underspecified","issue":%s,"ctx":%s}\n' \
      "$best_num" "$ctx"
    return 0
  fi
  return 0
}

# 3. enrich-bug-report
#    Open unlabeled issue describing a user-facing bug with reproduction steps.
check_enrich_bug_report() {
  local issues_json="$1"
  local best_num="" best_ts=""

  # Look for issues with bug-like indicators in title/body
  # Keywords: bug, broken, error, crash, fail, reproduce, issue, not working
  local candidates
  candidates=$(printf '%s' "$issues_json" | jq -c '
    [.[] | select(
      ((.labels | map(.name) | length) == 0) and
      (
        ((.title | ascii_downcase) | (
          contains("bug") or contains("broken") or
          contains("error") or contains("crash") or
          contains("fail") or contains("not working") or
          contains("reproduce")
        )) or
        ((.body // "") | ascii_downcase | (
          contains("reproduce") or contains("steps to") or
          contains("expected") or contains("actual") or
          contains("version:") or contains("environment:")
        ))
      )
    )]
  ' 2>/dev/null) || candidates="[]"

  local count
  count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  for i in $(seq 0 $((count - 1))); do
    local num ts
    num=$(printf '%s' "$candidates" | jq -r ".[$i].number")
    ts=$(printf '%s' "$candidates" | jq -r ".[$i].updated_at")

    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best_num="$num"
      best_ts="$ts"
    fi
  done

  if [ -n "$best_num" ]; then
    local ctx
    ctx=$(printf '%s' "$candidates" | jq -c ".[] | select(.number == $best_num) | {title, updated_at}")
    printf '{"task":"enrich-bug-report","issue":%s,"ctx":%s}\n' \
      "$best_num" "$ctx"
    return 0
  fi
  return 0
}

# 4. promote-tech-debt
#    tech-debt issue passing impact/effort heuristic.
check_promote_tech_debt() {
  local issues_json="$1"
  local best_num="" best_ts=""

  local candidates
  candidates=$(printf '%s' "$issues_json" | jq -c '
    [.[] | select(.labels | any(.name == "tech-debt"))]
  ' 2>/dev/null) || candidates="[]"

  local count
  count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  for i in $(seq 0 $((count - 1))); do
    local num ts body
    num=$(printf '%s' "$candidates" | jq -r ".[$i].number")
    ts=$(printf '%s' "$candidates" | jq -r ".[$i].updated_at")
    body=$(printf '%s' "$candidates" | jq -r ".[$i].body // \"\"")
    title=$(printf '%s' "$candidates" | jq -r ".[$i].title")

    # Impact/effort heuristic: body mentions "impact", "effort", "cost",
    # "slow", "performance", "memory", "bloat", or title has "tech-debt"
    local heuristic=false
    local check_text
    check_text=$(printf '%s\n%s' "$title" "$body" | tr '[:upper:]' '[:lower:]')

    if printf '%s' "$check_text" | grep -qE '(impact|effort|cost|slow|performance|memory|bloat|debt|refactor|cleanup)'; then
      heuristic=true
    fi

    if [ "$heuristic" = true ]; then
      if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
        best_num="$num"
        best_ts="$ts"
      fi
    fi
  done

  if [ -n "$best_num" ]; then
    local ctx
    ctx=$(printf '%s' "$candidates" | jq -c ".[] | select(.number == $best_num) | {title, updated_at}")
    printf '{"task":"promote-tech-debt","issue":%s,"ctx":%s}\n' \
      "$best_num" "$ctx"
    return 0
  fi
  return 0
}

# 5. bundle-dust
#    dust group in gardener/dust.jsonl with >= 3 distinct issues.
check_bundle_dust() {
  if [ ! -f "$DUST_FILE" ]; then
    return 0
  fi

  # Read dust entries and get unique group names
  local groups
  groups=$(jq -r '.group // empty' "$DUST_FILE" 2>/dev/null | sort -u) || groups=""

  if [ -z "$groups" ]; then
    return 0
  fi

  # Count distinct issues per group
  local best_group="" best_count=0
  while IFS= read -r group; do
    [ -z "$group" ] && continue
    # Count distinct issues in this group
    local count
    count=$(jq -r --arg g "$group" \
      'select(.group == $g) | .issue' "$DUST_FILE" 2>/dev/null | \
      sort -u | wc -l) || count=0
    if [ "$count" -ge 3 ] && [ "$count" -gt "$best_count" ]; then
      best_group="$group"
      best_count="$count"
    fi
  done <<< "$groups"

  if [ -n "$best_group" ]; then
    # Get the issues in this group
    local issues
    issues=$(jq -r --arg g "$best_group" \
      'select(.group == $g) | .issue' "$DUST_FILE" 2>/dev/null | \
      sort -un | tr '\n' ',' | sed 's/,$//') || issues=""

    local affected_paths
    affected_paths=$(printf '%s' "$issues" | jq -Rc 'split(",") | map(tonumber)')
    jq -n -c --argjson group_issues "$affected_paths" --arg group "$best_group" --argjson count "$best_count" \
      '{"task":"bundle-dust","issue":0,"ctx":{"affected_paths":$group_issues,"dust_group":$group,"dust_issue_count":$count}}'
    return 0
  fi
  return 0
}

# 6. agents-md-stale
#    AGENTS.md whose watermark <!-- last-reviewed: <sha> --> predates
#    git log head for its directory.
check_agents_md_stale() {
  if [ ! -f "$AGENTS_MD" ]; then
    return 0
  fi

  # Extract the review watermark SHA from AGENTS.md
  local review_sha
  review_sha=$(grep -oP '<!-- last-reviewed:\s*\K[0-9a-f]+' "$AGENTS_MD" 2>/dev/null) || review_sha=""

  if [ -z "$review_sha" ]; then
    return 0
  fi

  # Get the git log head for the directory containing AGENTS.md
  local md_dir
  md_dir=$(dirname "$AGENTS_MD")
  local dir_head
  dir_head=$(git -C "$md_dir" log -1 --format='%H' 2>/dev/null) || dir_head=""

  if [ -z "$dir_head" ]; then
    return 0
  fi

  # Check if the review SHA is older than the directory head
  if [ "$review_sha" != "${dir_head:0:${#review_sha}}" ]; then
    # The review SHA is different from current head — check if it's older
    local review_date head_date
    review_date=$(git -C "$md_dir" log -1 --format='%ct' "$review_sha" 2>/dev/null) || review_date=0
    head_date=$(git -C "$md_dir" log -1 --format='%ct' "$dir_head" 2>/dev/null) || head_date=0

    if [ "${review_date:-0}" -lt "${head_date:-0}" ]; then
      jq -n -c --arg path "$AGENTS_MD" --arg sha "$review_sha" --arg head "$dir_head" \
        '{"task":"agents-md-stale","issue":0,"ctx":{"agents_md_path":$path,"review_sha":$sha,"current_head":$head}}'
      return 0
    fi
  fi

  return 0
}

# 7. pitch-vision
#    Open vision issue with no architect pitch in ops repo.
check_pitch_vision() {
  local issues_json="$1"

  if [ -z "$OPS_REPO_ROOT" ]; then
    return 0
  fi

  local candidates
  candidates=$(printf '%s' "$issues_json" | jq -c '
    [.[] | select(.labels | any(.name == "vision"))]
  ' 2>/dev/null) || candidates="[]"

  local count
  count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  for i in $(seq 0 $((count - 1))); do
    local num ts
    num=$(printf '%s' "$candidates" | jq -r ".[$i].number")
    ts=$(printf '%s' "$candidates" | jq -r ".[$i].updated_at")

    # Check if there is an architect pitch in the ops repo for this issue
    local pitch_file="${OPS_REPO_ROOT}/knowledge/pitches/vision-${num}.md"
    if [ ! -f "$pitch_file" ]; then
      local title
      title=$(printf '%s' "$candidates" | jq -r ".[$i].title")
      jq -n -c --argjson issue "$num" --arg title "$title" --arg ts "$ts" \
        '{"task":"pitch-vision","issue":$issue,"ctx":{"title":$title,"updated_at":$ts}}'
      return 0
    fi
  done

  return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Fetch all open issues (single API call with pagination)
  local issues_json
  issues_json=$(fetch_open_issues)

  # Priority 1: blocker-starving-the-factory
  local result
  result=$(check_blocker_starving "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 2: enrich-underspecified
  result=$(check_enrich_underspecified "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 3: enrich-bug-report
  result=$(check_enrich_bug_report "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 4: promote-tech-debt
  result=$(check_promote_tech_debt "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 5: bundle-dust
  result=$(check_bundle_dust)
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 6: agents-md-stale
  result=$(check_agents_md_stale)
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 7: pitch-vision
  result=$(check_pitch_vision "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # CLEAN — nothing actionable
  exit 0
}

main
