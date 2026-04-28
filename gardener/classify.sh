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
#   7. file-subissues              — APPROVED architect pitch PR with no `## Filed:` marker
#   8. pitch-vision                — open vision issue with no architect pitch
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
    [.[] | select(.labels | any(.name == "tech-debt"))
         | select(.labels | map(.name) | all(. != "backlog"))
         | select(.labels | map(.name) | all(. != "underspecified"))]
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
#    Any AGENTS.md whose watermark <!-- last-reviewed: <sha> --> predates
#    git log head for its directory. Walks every AGENTS.md in the repo and
#    surfaces the one with the oldest watermark relative to its directory's
#    HEAD (most-stale-first).
check_agents_md_stale() {
  # Find all AGENTS.md files tracked in the repo (skip .git, vendor dirs).
  local agents_md_files
  agents_md_files=$(git -C "$FACTORY_ROOT" ls-files '*AGENTS.md' 'AGENTS.md' 2>/dev/null) || agents_md_files=""

  if [ -z "$agents_md_files" ]; then
    return 0
  fi

  local best_path="" best_sha="" best_head="" best_age=0

  while IFS= read -r rel_path; do
    [ -z "$rel_path" ] && continue
    local md_path="$FACTORY_ROOT/$rel_path"
    [ -f "$md_path" ] || continue

    # Extract the review watermark SHA from this AGENTS.md
    local review_sha
    review_sha=$(grep -oP '<!-- last-reviewed:\s*\K[0-9a-f]+' "$md_path" 2>/dev/null) || review_sha=""
    [ -z "$review_sha" ] && continue

    # Get the git log head for the directory containing this AGENTS.md
    local md_dir
    md_dir=$(dirname "$md_path")
    local dir_head
    dir_head=$(git -C "$md_dir" log -1 --format='%H' -- "$md_dir" 2>/dev/null) || dir_head=""
    [ -z "$dir_head" ] && continue

    # If the watermark already matches HEAD (full or prefix), skip.
    if [ "$review_sha" = "${dir_head:0:${#review_sha}}" ]; then
      continue
    fi

    # Confirm the watermark is strictly older than dir HEAD by commit time.
    local review_date head_date
    review_date=$(git -C "$md_dir" log -1 --format='%ct' "$review_sha" 2>/dev/null) || review_date=0
    head_date=$(git -C "$md_dir" log -1 --format='%ct' "$dir_head" 2>/dev/null) || head_date=0

    if [ "${review_date:-0}" -lt "${head_date:-0}" ]; then
      local age=$(( head_date - review_date ))
      # Most-stale wins — surfaces the file most overdue for refresh first.
      if [ -z "$best_path" ] || [ "$age" -gt "$best_age" ]; then
        best_path="$md_path"
        best_sha="$review_sha"
        best_head="$dir_head"
        best_age="$age"
      fi
    fi
  done <<< "$agents_md_files"

  if [ -n "$best_path" ]; then
    jq -n -c --arg path "$best_path" --arg sha "$best_sha" --arg head "$best_head" \
      '{"task":"agents-md-stale","issue":0,"ctx":{"agents_md_path":$path,"review_sha":$sha,"current_head":$head}}'
    return 0
  fi

  return 0
}

# 7. file-subissues
#    Open ops-repo PR with `architect:` title prefix that has been APPROVED
#    via Forgejo review state and whose body lacks a `## Filed:` marker.
#    Surfaces the pitch body and the parsed `<!-- filer:begin -->` ...
#    `<!-- filer:end -->` block so the formula can fan out sub-issues to
#    the project repo. Sentinel = absence of `## Filed:` marker — re-runs
#    on already-filed PRs are a no-op (this check skips them).
#
#    Slotted above pitch-vision so any APPROVED pitch is fanned out before
#    new pitches are generated (#902).
check_file_subissues() {
  if [ -z "${FORGE_OPS_REPO:-}" ]; then
    return 0
  fi

  # Fetch open ops-repo PRs (single page is fine — 50 open architect PRs is
  # already pathological; the 3-open-PR cap in pitch-vision keeps this small).
  local prs_json
  prs_json=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=50" \
    2>/dev/null) || return 0

  local arch_prs
  arch_prs=$(printf '%s' "$prs_json" \
    | jq -c '[.[] | select(.title | startswith("architect:"))]' 2>/dev/null) \
    || arch_prs="[]"

  local count
  count=$(printf '%s' "$arch_prs" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  local i pr_num pr_body reviews approved filer_block
  for i in $(seq 0 $((count - 1))); do
    pr_num=$(printf '%s' "$arch_prs" | jq -r ".[$i].number")
    pr_body=$(printf '%s' "$arch_prs" | jq -r ".[$i].body // \"\"")

    # Sentinel: skip if already filed.
    if printf '%s' "$pr_body" | grep -qE '^## Filed:'; then
      continue
    fi

    # Must contain a filer:begin/end block to fan out.
    if ! printf '%s' "$pr_body" | grep -q '<!-- filer:begin -->'; then
      continue
    fi

    # Forgejo APPROVED review = design-finalized signal (architect lifecycle).
    reviews=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
      "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr_num}/reviews" \
      2>/dev/null) || continue

    approved=$(printf '%s' "$reviews" \
      | jq -e '[.[] | select(.state == "APPROVED")] | length > 0' \
        >/dev/null 2>&1 && echo true || echo false)
    [ "$approved" = "true" ] || continue

    # Extract the filer block (between markers, exclusive).
    filer_block=$(printf '%s' "$pr_body" | awk '
      /<!-- filer:begin -->/ { in_block=1; next }
      /<!-- filer:end -->/   { in_block=0; next }
      in_block { print }
    ')

    if [ -z "$filer_block" ]; then
      continue
    fi

    jq -n -c \
      --argjson pr "$pr_num" \
      --arg body "$pr_body" \
      --arg block "$filer_block" \
      '{"task":"file-subissues","ops_pr":$pr,
        "ctx":{"pitch_body":$body,"filer_block":$block}}'
    return 0
  done
  return 0
}

# 8. pitch-vision
#    Open vision issue with no open architect-prefixed PR and no merged
#    sprint PR on the ops repo. Surfaces a curated codebase index by
#    grepping vision keywords against AGENTS.md so the formula can load
#    only relevant files into context — not the whole tree (#877).
#
#    Dedup mirrors architect/architect-run.sh: skip if the vision already
#    has an open or merged ops-repo PR referencing it. The 3-open-PR cap
#    is enforced here too — if 3+ architect-prefixed PRs are open, no
#    new pitch is surfaced (formula is not invoked).
check_pitch_vision() {
  local issues_json="$1"

  # Need ops-repo access to dedup against existing pitch PRs.
  if [ -z "${FORGE_OPS_REPO:-}" ]; then
    return 0
  fi

  local candidates
  candidates=$(printf '%s' "$issues_json" | jq -c '
    [.[] | select(.labels | any(.name == "vision"))
         | select(.labels | map(.name) | all(. != "in-progress"))]
  ' 2>/dev/null) || candidates="[]"

  local count
  count=$(printf '%s' "$candidates" | jq 'length' 2>/dev/null) || count=0
  [ "$count" -eq 0 ] && return 0

  # Fetch all architect-prefixed PRs (open + closed) once. Dedup against
  # PR titles/bodies that reference the vision number.
  local prs_json
  prs_json=$(curl -sf -H "Authorization: token $FORGE_TOKEN" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=all&limit=100" \
    2>/dev/null) || prs_json='[]'

  # 3-open-PR cap on ops repo (matches architect-run.sh precondition).
  local open_arch_count
  open_arch_count=$(printf '%s' "$prs_json" \
    | jq '[.[] | select(.state == "open") | select(.title | startswith("architect:"))] | length' \
    2>/dev/null) || open_arch_count=0
  if [ "${open_arch_count:-0}" -ge 3 ]; then
    return 0
  fi

  # Build a set of vision issue numbers already pitched (open or merged).
  # An ops-repo PR "pitches" a vision if its title starts with `architect:`
  # AND its body references `#NNN` for that vision number.
  local pitched_nums
  pitched_nums=$(printf '%s' "$prs_json" \
    | jq -r '
        .[] | select(.title | startswith("architect:"))
            | select(.state == "open" or (.merged // false))
            | .body // ""' \
    2>/dev/null \
    | grep -oE '#[0-9]+' | tr -d '#' | sort -u) || pitched_nums=""

  # Build candidate keyword set from AGENTS.md once: every backtick-wrapped
  # path is a usable index entry. The formula receives a per-vision subset
  # filtered by keyword match against the vision title/body.
  local agents_md_paths
  # shellcheck disable=SC2016  # backticks in regex are literal
  agents_md_paths=$(grep -hoE '`[a-zA-Z0-9_./-]+\.(sh|py|js|ts|tsx|toml|md|hcl|yml|yaml|json|rs|go)`' \
    "$FACTORY_ROOT/AGENTS.md" \
    "$FACTORY_ROOT/gardener/AGENTS.md" \
    "$FACTORY_ROOT/architect/AGENTS.md" \
    2>/dev/null \
    | tr -d '`' | sort -u) || agents_md_paths=""

  local best_num="" best_ts=""
  for i in $(seq 0 $((count - 1))); do
    local num ts
    num=$(printf '%s' "$candidates" | jq -r ".[$i].number")
    ts=$(printf '%s' "$candidates" | jq -r ".[$i].updated_at")

    # Skip if already pitched (open or merged ops-repo PR refs this vision).
    if printf '%s\n' "$pitched_nums" | grep -qx "$num"; then
      continue
    fi

    # Most recently updated wins (FIFO within the bucket — operator-touched
    # vision floats to top).
    if [ -z "$best_ts" ] || [[ "$ts" > "$best_ts" ]]; then
      best_num="$num"
      best_ts="$ts"
    fi
  done

  if [ -z "$best_num" ]; then
    return 0
  fi

  # Build ctx for the chosen vision: title, body, related #refs, and the
  # curated codebase_index_paths.
  local title body
  title=$(printf '%s' "$candidates" | jq -r ".[] | select(.number == $best_num) | .title")
  body=$(printf '%s' "$candidates" | jq -r ".[] | select(.number == $best_num) | .body // \"\"")

  # related_issues: every #NNN referenced in the body (excluding the vision
  # itself), de-duplicated, capped at 20.
  local related_json
  related_json=$(printf '%s' "$body" \
    | grep -oE '#[0-9]+' | sort -u | head -20 \
    | jq -R . | jq -sc .) || related_json='[]'

  # codebase_index_paths: keywords from title (lowercased, length>=4,
  # alphanumeric only) → grep AGENTS.md path list for any keyword as
  # substring → unique paths, capped at 10.
  local keywords paths_json paths_list
  keywords=$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length >= 4 { print }' \
    | sort -u)

  paths_list=""
  if [ -n "$agents_md_paths" ] && [ -n "$keywords" ]; then
    paths_list=$(while IFS= read -r p; do
      [ -z "$p" ] && continue
      while IFS= read -r kw; do
        [ -z "$kw" ] && continue
        if printf '%s' "$p" | tr '[:upper:]' '[:lower:]' | grep -qF "$kw"; then
          printf '%s\n' "$p"
          break
        fi
      done <<< "$keywords"
    done <<< "$agents_md_paths" | sort -u | head -10)
  fi

  paths_json=$(printf '%s' "$paths_list" \
    | grep -v '^$' | jq -R . | jq -sc .) || paths_json='[]'

  jq -n -c \
    --argjson issue "$best_num" \
    --arg title "$title" \
    --arg body "$body" \
    --argjson related "$related_json" \
    --argjson paths "$paths_json" \
    '{"task":"pitch-vision","issue":$issue,
      "ctx":{"title":$title,"body":$body,
             "related_issues":$related,
             "codebase_index_paths":$paths}}'
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

  # Priority 7: file-subissues — fan out APPROVED architect pitches first
  # so the project-repo work is unblocked before new pitches are generated.
  result=$(check_file_subissues)
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # Priority 8: pitch-vision
  result=$(check_pitch_vision "$issues_json")
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  # CLEAN — nothing actionable
  exit 0
}

main
