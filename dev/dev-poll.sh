#!/usr/bin/env bash
# dev-poll.sh — Pull-based scheduler: find the next ready issue and start dev-agent
#
# Pull system: issues labeled "backlog" are candidates. An issue is READY when
# ALL its dependency issues are closed (and their PRs merged).
# No "todo" label needed — readiness is derived from reality.
#
# Priority:
#   1. Orphaned "in-progress" issues (agent died or PR needs attention)
#   2. Ready "backlog" issues (all deps merged)
#
# Usage:
#   cron every 10min
#   dev-poll.sh [projects/harb.toml]   # optional project config

set -euo pipefail

# Load shared environment (with optional project TOML override)
export PROJECT_TOML="${1:-}"
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"

# Track CI fix attempts per PR to avoid infinite respawn loops
CI_FIX_TRACKER="${FACTORY_ROOT}/dev/ci-fixes-${PROJECT_NAME:-harb}.json"
CI_FIX_LOCK="${CI_FIX_TRACKER}.lock"
ci_fix_count() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "import json,sys;d=json.load(open('$CI_FIX_TRACKER')) if __import__('os').path.exists('$CI_FIX_TRACKER') else {};print(d.get(str($pr),0))" 2>/dev/null || echo 0
}
ci_fix_increment() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
d=json.load(open(f)) if os.path.exists(f) else {}
d[str($pr)]=d.get(str($pr),0)+1
json.dump(d,open(f,'w'))
" 2>/dev/null || true
}
ci_fix_reset() {
  local pr="$1"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
d=json.load(open(f)) if os.path.exists(f) else {}
d.pop(str($pr),None)
json.dump(d,open(f,'w'))
" 2>/dev/null || true
}
ci_fix_check_and_increment() {
  local pr="$1"
  local check_only="${2:-}"
  flock "$CI_FIX_LOCK" python3 -c "
import json,os
f='$CI_FIX_TRACKER'
check_only = '${check_only}' == 'check_only'
d=json.load(open(f)) if os.path.exists(f) else {}
count=d.get(str($pr),0)
if count>3:
    print('exhausted:'+str(count))
elif count==3:
    d[str($pr)]=4
    json.dump(d,open(f,'w'))
    print('exhausted_first_time:3')
elif check_only:
    print('ok:'+str(count))
else:
    count+=1
    d[str($pr)]=count
    json.dump(d,open(f,'w'))
    print('ok:'+str(count))
" 2>/dev/null || echo "exhausted:99"
}

# Check whether an issue/PR has been escalated (unprocessed or processed)
is_escalated() {
  local issue="$1" pr="$2"
  python3 -c "
import json, sys
try:
  issue, pr = int('${issue}'), int('${pr}')
except (ValueError, TypeError):
  sys.exit(1)
for path in ['${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl',
             '${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.done.jsonl']:
  try:
    with open(path) as fh:
      for line in fh:
        line = line.strip()
        if not line:
          continue
        d = json.loads(line)
        if d.get('issue') == issue and d.get('pr') == pr:
          sys.exit(0)
  except OSError:
    pass
sys.exit(1)
" 2>/dev/null && return 0 || return 1
}

# =============================================================================
# HELPER: handle CI-exhaustion check/escalate (DRY for 3 call sites)
# Sets CI_FIX_ATTEMPTS for caller use. Returns 0 if exhausted, 1 if not.
#
# Pass "check_only" as third arg for the backlog scan path: ok-counts are
# returned without incrementing (deferred to launch time so a WAITING_PRS
# exit cannot waste a fix attempt). The 3→4 sentinel bump is always atomic
# regardless of mode, preventing duplicate escalation writes from concurrent
# pollers.
# =============================================================================
handle_ci_exhaustion() {
  local pr_num="$1" issue_num="$2"
  local check_only="${3:-}"
  local result

  # Fast path: already in the escalation file — skip without touching counter.
  if is_escalated "$issue_num" "$pr_num"; then
    CI_FIX_ATTEMPTS=$(ci_fix_count "$pr_num")
    log "PR #${pr_num} (issue #${issue_num}) already escalated (${CI_FIX_ATTEMPTS} attempts) — skipping"
    return 0
  fi

  # Single flock-protected call: read + threshold-check + conditional bump.
  # In check_only mode, ok-counts are returned without incrementing (deferred
  # to launch time). In both modes, the 3→4 sentinel bump is atomic, so only
  # one concurrent poller can ever receive exhausted_first_time:3 and write
  # the escalation entry.
  result=$(ci_fix_check_and_increment "$pr_num" "$check_only")
  case "$result" in
    ok:*)
      CI_FIX_ATTEMPTS="${result#ok:}"
      return 1
      ;;
    exhausted_first_time:*)
      CI_FIX_ATTEMPTS="${result#exhausted_first_time:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — escalated to gardener, skipping"
      echo "{\"issue\":${issue_num},\"pr\":${pr_num},\"project\":\"${PROJECT_NAME}\",\"reason\":\"ci_exhausted_poll\",\"attempts\":${CI_FIX_ATTEMPTS},\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        >> "${FACTORY_ROOT}/supervisor/escalations-${PROJECT_NAME}.jsonl"
      matrix_send "dev" "🚨 PR #${pr_num} (issue #${issue_num}) CI failed after ${CI_FIX_ATTEMPTS} attempts — escalated" 2>/dev/null || true
      ;;
    exhausted:*)
      CI_FIX_ATTEMPTS="${result#exhausted:}"
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — escalated to gardener, skipping"
      ;;
    *)
      CI_FIX_ATTEMPTS=99
      log "PR #${pr_num} (issue #${issue_num}) CI exhausted (${CI_FIX_ATTEMPTS} attempts) — escalated to gardener, skipping"
      ;;
  esac
  return 0
}

# shellcheck disable=SC2034
REPO="${CODEBERG_REPO}"

API="${CODEBERG_API}"
LOCKFILE="/tmp/dev-agent-${PROJECT_NAME:-harb}.lock"
LOGFILE="${FACTORY_ROOT}/dev/dev-agent-${PROJECT_NAME:-harb}.log"
PREFLIGHT_RESULT="/tmp/dev-agent-preflight.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() {
  printf '[%s] poll: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >> "$LOGFILE"
}

# --- Check if dev-agent already running ---
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "agent running (PID ${LOCK_PID})"
    exit 0
  fi
  rm -f "$LOCKFILE"
fi

# --- Memory guard ---
AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
if [ "$AVAIL_MB" -lt 2000 ]; then
  log "SKIP: only ${AVAIL_MB}MB available (need 2000MB)"
  matrix_send "dev" "⚠️ Low memory (${AVAIL_MB}MB) — skipping dev-agent" 2>/dev/null || true
  exit 0
fi

# =============================================================================
# HELPER: check if a dependency issue is fully resolved (closed + PR merged)
# =============================================================================
dep_is_merged() {
  local dep_num="$1"

  # Check issue is closed
  local dep_state
  dep_state=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/issues/${dep_num}" | jq -r '.state // "open"')
  if [ "$dep_state" != "closed" ]; then
    return 1
  fi

  # Issue closed = dep satisfied. The scheduler only closes issues after
  # merging, so closed state is trustworthy. No need to hunt for the
  # specific PR — that was over-engineering that caused false negatives.
  return 0
}

# =============================================================================
# HELPER: extract dependency numbers from issue body
# =============================================================================
get_deps() {
  local issue_body="$1"
  # Shared parser: lib/parse-deps.sh (single source of truth)
  echo "$issue_body" | bash "${FACTORY_ROOT}/lib/parse-deps.sh"
}

# =============================================================================
# HELPER: check if issue is ready (all deps merged)
# =============================================================================
issue_is_ready() {
  local issue_num="$1"
  local issue_body="$2"

  local deps
  deps=$(get_deps "$issue_body")

  if [ -z "$deps" ]; then
    # No dependencies — always ready
    return 0
  fi

  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if ! dep_is_merged "$dep"; then
      log "  #${issue_num} blocked: dep #${dep} not merged"
      return 1
    fi
  done <<< "$deps"

  return 0
}

# =============================================================================
# PRIORITY 1: orphaned in-progress issues
# =============================================================================
log "checking for in-progress issues"
ORPHANS_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues?state=open&labels=in-progress&limit=10&type=issues")

ORPHAN_COUNT=$(echo "$ORPHANS_JSON" | jq 'length')
if [ "$ORPHAN_COUNT" -gt 0 ]; then
  ISSUE_NUM=$(echo "$ORPHANS_JSON" | jq -r '.[0].number')

  # Formula guard: formula-labeled issues should not be worked on by dev-agent.
  # Remove in-progress label and skip to prevent infinite respawn cycle (#115).
  ORPHAN_LABELS=$(echo "$ORPHANS_JSON" | jq -r '.[0].labels[].name' 2>/dev/null) || true
  if echo "$ORPHAN_LABELS" | grep -qw 'formula'; then
    log "issue #${ISSUE_NUM} has 'formula' label — removing in-progress, skipping"
    curl -sf -X DELETE -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/issues/${ISSUE_NUM}/labels/in-progress" >/dev/null 2>&1 || true
    exit 0
  fi

  # Check if there's already an open PR for this issue
  HAS_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" \
    '.[] | select(.head.ref == $branch) | .number' | head -1) || true

  if [ -n "$HAS_PR" ]; then
    PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true

    # Check formal reviews
    HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}/reviews" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${HAS_PR}/reviews" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      log "PR #${HAS_PR} approved + CI green → spawning dev-agent to merge"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      exit 0

    # Do NOT gate REQUEST_CHANGES on ci_passed: act immediately even if CI is
    # pending/unknown. Definitive CI failure is handled by the elif below.
    elif [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
      log "issue #${ISSUE_NUM} PR #${HAS_PR} has REQUEST_CHANGES — spawning agent"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (review fix)"
      exit 0

    elif ! ci_passed "$CI_STATE" && [ "$CI_STATE" != "" ] && [ "$CI_STATE" != "pending" ] && [ "$CI_STATE" != "unknown" ]; then
      if handle_ci_exhaustion "$HAS_PR" "$ISSUE_NUM"; then
        # Fall through to backlog scan instead of exit
        :
      else
        log "issue #${ISSUE_NUM} PR #${HAS_PR} CI failed — spawning agent to fix (attempt ${CI_FIX_ATTEMPTS}/3)"
        nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
        log "started dev-agent PID $! for issue #${ISSUE_NUM} (CI fix)"
        exit 0
      fi

    else
      log "issue #${ISSUE_NUM} has open PR #${HAS_PR} (CI: ${CI_STATE}, waiting)"
    fi
  else
    log "recovering orphaned issue #${ISSUE_NUM} (no PR found)"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for issue #${ISSUE_NUM} (recovery)"
    exit 0
  fi
fi

# =============================================================================
# PRIORITY 1.5: any open PR with REQUEST_CHANGES or CI failure (stuck PRs)
# =============================================================================
log "checking for stuck PRs"
OPEN_PRS=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/pulls?state=open&limit=20")

for i in $(seq 0 $(($(echo "$OPEN_PRS" | jq 'length') - 1))); do
  PR_NUM=$(echo "$OPEN_PRS" | jq -r ".[$i].number")
  PR_BRANCH=$(echo "$OPEN_PRS" | jq -r ".[$i].head.ref")
  PR_SHA=$(echo "$OPEN_PRS" | jq -r ".[$i].head.sha")

  # Extract issue number from branch name (fix/issue-NNN), PR title (#NNN), or PR body (Closes #NNN)
  PR_TITLE=$(echo "$OPEN_PRS" | jq -r ".[$i].title")
  PR_BODY=$(echo "$OPEN_PRS" | jq -r ".[$i].body // \"\"")
  STUCK_ISSUE=$(echo "$PR_BRANCH" | grep -oP '(?<=fix/issue-)\d+' || true)
  if [ -z "$STUCK_ISSUE" ]; then
    STUCK_ISSUE=$(echo "$PR_TITLE" | grep -oP '#\K\d+' | tail -1 || true)
  fi
  if [ -z "$STUCK_ISSUE" ]; then
    STUCK_ISSUE=$(echo "$PR_BODY" | grep -oiP '(?:closes|fixes|resolves)\s*#\K\d+' | head -1 || true)
  fi
  if [ -z "$STUCK_ISSUE" ]; then
    log "PR #${PR_NUM} has no issue ref — cannot spawn dev-agent, skipping"
    continue
  fi

  CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true
  HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews" | \
    jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true
  HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls/${PR_NUM}/reviews" | \
    jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true

  # Spawn agent to merge if approved + CI green
  if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) approved + CI green → spawning dev-agent to merge"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM} (agent-merge)"
    exit 0
  fi

  # Stuck: REQUEST_CHANGES or CI failure → spawn agent
  # Do NOT gate REQUEST_CHANGES on ci_passed: if a reviewer leaves REQUEST_CHANGES
  # while CI is still pending/unknown, we must act immediately rather than wait for
  # CI to settle. Definitive CI failure (non-pending, non-unknown) is handled by
  # the elif below, so we only spawn here when CI has not definitively failed.
  if [ "${HAS_CHANGES:-0}" -gt 0 ] && { ci_passed "$CI_STATE" || [ "$CI_STATE" = "pending" ] || [ "$CI_STATE" = "unknown" ] || [ -z "$CI_STATE" ]; }; then
    log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) has REQUEST_CHANGES — fixing first"
    nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
    log "started dev-agent PID $! for stuck PR #${PR_NUM}"
    exit 0
  elif ! ci_passed "$CI_STATE" && [ "$CI_STATE" != "" ] && [ "$CI_STATE" != "pending" ] && [ "$CI_STATE" != "unknown" ]; then
    if handle_ci_exhaustion "$PR_NUM" "$STUCK_ISSUE"; then
      continue  # skip this PR, check next stuck PR or fall through to backlog
    else
      log "PR #${PR_NUM} (issue #${STUCK_ISSUE}) CI failed — fixing (attempt ${CI_FIX_ATTEMPTS}/3)"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$STUCK_ISSUE" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for stuck PR #${PR_NUM}"
      exit 0
    fi
  fi
done

# =============================================================================
# PRIORITY 2: find ready backlog issues (pull system)
# =============================================================================
log "scanning backlog for ready issues"
BACKLOG_JSON=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
  "${API}/issues?state=open&labels=backlog&limit=20&type=issues")

BACKLOG_COUNT=$(echo "$BACKLOG_JSON" | jq 'length')
if [ "$BACKLOG_COUNT" -eq 0 ]; then
  log "no backlog issues"
  exit 0
fi

log "found ${BACKLOG_COUNT} backlog issues"

# Check each for readiness
READY_ISSUE=""
for i in $(seq 0 $((BACKLOG_COUNT - 1))); do
  ISSUE_NUM=$(echo "$BACKLOG_JSON" | jq -r ".[$i].number")
  ISSUE_BODY=$(echo "$BACKLOG_JSON" | jq -r ".[$i].body // \"\"")

  # Formula guard: formula-labeled issues must not be picked up by dev-agent.
  # A formula issue that accidentally acquires the backlog label should be skipped.
  ISSUE_LABELS=$(echo "$BACKLOG_JSON" | jq -r ".[$i].labels[].name" 2>/dev/null) || true
  if echo "$ISSUE_LABELS" | grep -qw 'formula'; then
    log "issue #${ISSUE_NUM} has 'formula' label — skipping in backlog scan"
    continue
  fi

  if ! issue_is_ready "$ISSUE_NUM" "$ISSUE_BODY"; then
    continue
  fi

  # Check if there's already an open PR for this issue that needs attention
  EXISTING_PR=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
    "${API}/pulls?state=open&limit=20" | \
    jq -r --arg branch "fix/issue-${ISSUE_NUM}" --arg num "#${ISSUE_NUM}" \
    '.[] | select((.head.ref == $branch) or (.title | contains($num))) | .number' | head -1) || true

  if [ -n "$EXISTING_PR" ]; then
    PR_SHA=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}" | jq -r '.head.sha') || true
    CI_STATE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/commits/${PR_SHA}/status" | jq -r '.state // "unknown"') || true
    HAS_APPROVE=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews" | \
      jq -r '[.[] | select(.state == "APPROVED") | select(.stale == false)] | length') || true
    HAS_CHANGES=$(curl -sf -H "Authorization: token ${CODEBERG_TOKEN}" \
      "${API}/pulls/${EXISTING_PR}/reviews" | \
      jq -r '[.[] | select(.state == "REQUEST_CHANGES") | select(.stale == false)] | length') || true

    if ci_passed "$CI_STATE" && [ "${HAS_APPROVE:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} approved + CI green → spawning dev-agent to merge"
      nohup "${SCRIPT_DIR}/dev-agent.sh" "$ISSUE_NUM" >> "$LOGFILE" 2>&1 &
      log "started dev-agent PID $! for issue #${ISSUE_NUM} (agent-merge)"
      exit 0

    elif [ "${HAS_CHANGES:-0}" -gt 0 ]; then
      log "#${ISSUE_NUM} PR #${EXISTING_PR} has REQUEST_CHANGES — picking up"
      READY_ISSUE="$ISSUE_NUM"
      break

    elif ! ci_passed "$CI_STATE" && [ "$CI_STATE" != "" ] && [ "$CI_STATE" != "pending" ] && [ "$CI_STATE" != "unknown" ]; then
      if handle_ci_exhaustion "$EXISTING_PR" "$ISSUE_NUM" "check_only"; then
        # Don't add to WAITING_PRS — escalated PRs should not block new work
        continue
      fi
      log "#${ISSUE_NUM} PR #${EXISTING_PR} CI failed — picking up (attempt $((CI_FIX_ATTEMPTS+1))/3)"
      READY_ISSUE="$ISSUE_NUM"
      READY_PR_FOR_INCREMENT="$EXISTING_PR"
      break

    else
      log "#${ISSUE_NUM} PR #${EXISTING_PR} exists (CI: ${CI_STATE}, waiting)"
      WAITING_PRS="${WAITING_PRS:-}${WAITING_PRS:+, }#${EXISTING_PR}"
      continue
    fi
  fi

  READY_ISSUE="$ISSUE_NUM"
  log "#${ISSUE_NUM} is READY (all deps merged, no existing PR)"
  break
done

# Single-threaded per project: if any issue has an open PR waiting for review/CI,
# don't start new work — let the pipeline drain first
if [ -n "$READY_ISSUE" ] && [ -n "${WAITING_PRS:-}" ]; then
  log "holding #${READY_ISSUE} — waiting for open PR(s) to land first: ${WAITING_PRS}"
  exit 0
fi

if [ -z "$READY_ISSUE" ]; then
  log "no ready issues (all blocked by unmerged deps)"
  exit 0
fi

# =============================================================================
# LAUNCH: start dev-agent for the ready issue
# =============================================================================
# Deferred CI fix increment — only now that we're certain we are launching.
# Uses the atomic ci_fix_check_and_increment (inside handle_ci_exhaustion) so
# the counter is bumped exactly once even under concurrent poll invocations,
# and a WAITING_PRS exit above cannot silently consume a fix attempt.
if [ -n "${READY_PR_FOR_INCREMENT:-}" ]; then
  if handle_ci_exhaustion "$READY_PR_FOR_INCREMENT" "$READY_ISSUE"; then
    # exhausted (another poller incremented between scan and launch) — bail out
    exit 0
  fi
fi

log "launching dev-agent for #${READY_ISSUE}"
matrix_send "dev" "🚀 Starting dev-agent on issue #${READY_ISSUE}" 2>/dev/null || true
rm -f "$PREFLIGHT_RESULT"

nohup "${SCRIPT_DIR}/dev-agent.sh" "$READY_ISSUE" >> "$LOGFILE" 2>&1 &
AGENT_PID=$!

# Wait briefly for preflight (agent writes result before claiming)
for _w in $(seq 1 30); do
  if [ -f "$PREFLIGHT_RESULT" ]; then
    break
  fi
  if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    break
  fi
  sleep 2
done

if [ -f "$PREFLIGHT_RESULT" ]; then
  PREFLIGHT_STATUS=$(jq -r '.status // "unknown"' < "$PREFLIGHT_RESULT")
  rm -f "$PREFLIGHT_RESULT"

  case "$PREFLIGHT_STATUS" in
    ready)
      log "dev-agent running for #${READY_ISSUE}"
      ;;
    unmet_dependency)
      log "#${READY_ISSUE} has code-level dependency (preflight blocked)"
      wait "$AGENT_PID" 2>/dev/null || true
      ;;
    too_large)
      REASON=$(jq -r '.reason // "unspecified"' < "$PREFLIGHT_RESULT" 2>/dev/null || echo "unspecified")
      log "#${READY_ISSUE} too large: ${REASON}"
      # Label as underspecified
      curl -sf -X POST -H "Authorization: token ${CODEBERG_TOKEN}" \
        -H "Content-Type: application/json" \
        "${API}/issues/${READY_ISSUE}/labels" \
        -d '{"labels":["underspecified"]}' >/dev/null 2>&1 || true
      ;;
    already_done)
      log "#${READY_ISSUE} already done"
      ;;
    *)
      log "#${READY_ISSUE} unknown preflight: ${PREFLIGHT_STATUS}"
      ;;
  esac
elif kill -0 "$AGENT_PID" 2>/dev/null; then
  log "dev-agent running for #${READY_ISSUE} (passed preflight)"
else
  log "dev-agent exited for #${READY_ISSUE} without preflight result"
fi
