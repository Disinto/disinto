#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# review-pr.sh — Synchronous reviewer agent for a single PR
#
# Usage: ./review-pr.sh <pr-number> [--force]
#
# Architecture:
#   Synchronous bash loop using claude -p (one-shot invocations).
#   Session continuity via --resume and .sid file.
#   Re-review resumes the original session — Claude remembers its prior review.
#   Re-review context is budgeted (#1257): prior rounds are injected as
#   compact digests (verdict + findings per round, capped), not full bodies.
#
# Flow:
#   1. Fetch PR metadata (title, body, head, base, SHA, CI state)
#   2. Detect re-review (prior rounds at other SHAs → compact digests +
#      incremental diff — both bounded, #1257)
#   3. Create review worktree, checkout PR head
#   4. Load review formula
#   5. agent_run(worktree, prompt) → Claude reviews, writes verdict JSON
#   6. Parse verdict, post as Forge review (APPROVE / REQUEST_CHANGES / COMMENT)
#   7. Save session ID to .sid file for re-review continuity
#
# Session file: /tmp/review-session-{project}-{pr}.sid
set -euo pipefail

# Load shared environment and libraries
source "$(dirname "$0")/../lib/env.sh"
source "$(dirname "$0")/../lib/ci-helpers.sh"
source "$(dirname "$0")/../lib/worktree.sh"
source "$(dirname "$0")/../lib/agent-sdk.sh"
# shellcheck source=../lib/formula-session.sh
source "$(dirname "$0")/../lib/formula-session.sh"
# shellcheck source=../lib/stale-base-check.sh
source "$(dirname "$0")/../lib/stale-base-check.sh"

# Auto-pull factory code to pick up merged fixes before any logic runs.
# stdout must stay silent: the poller tail's this script's output for
# failure messages, and "Already up to date." is not a useful reason (#1075).
git -C "$FACTORY_ROOT" pull --ff-only origin main >/dev/null 2>&1 || true

# --- Config ---
PR_NUMBER="${1:?Usage: review-pr.sh <pr-number> [--force]}"

# Change to project repo early — required before any git commands
# (factory root is not a git repo after image rebuild)
cd "${PROJECT_REPO_ROOT}"
FORCE="${2:-}"
API="${FORGE_API}"
LOGFILE="${DISINTO_LOG_DIR}/review/review.log"
WORKTREE="/tmp/${PROJECT_NAME}-review-${PR_NUMBER}"
SID_FILE="/tmp/review-session-${PROJECT_NAME}-${PR_NUMBER}.sid"
OUTPUT_FILE="/tmp/${PROJECT_NAME}-review-output-${PR_NUMBER}.json"
LOCKFILE="/tmp/${PROJECT_NAME}-review.lock"
STATUSFILE="/tmp/${PROJECT_NAME}-review-status"
MAX_DIFF=25000
# Diffs larger than this are NOT pasted into the prompt: the agent gets the
# worktree path + git commands and reads the files locally (it has read/bash).
# A pasted 25KB diff can be auto-compacted away mid-review and lose file
# coverage (#1256, #1260); a worktree read survives compaction.
DIFF_THRESHOLD=12000
# Prior review rounds are injected as compact digests (verdict + findings
# list per round) instead of full review bodies; each digest's findings list
# is capped at this many bytes (#1257).
DIGEST_CAP=2048
REVIEW_TMPDIR=$(mktemp -d)

log() { printf '[%s] PR#%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" >> "$LOGFILE"; }
status() { printf '[%s] PR #%s: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$PR_NUMBER" "$*" > "$STATUSFILE"; log "$*"; }

# cleanup — remove temp files (NOT lockfile — cleanup_on_exit handles that)
cleanup() {
  rm -rf "$REVIEW_TMPDIR" "$STATUSFILE"
}

# cleanup_on_exit — defensive cleanup: remove lockfile if we own it, kill residual children
# This handles the case where review-pr.sh is terminated unexpectedly (e.g., watchdog SIGTERM)
cleanup_on_exit() {
  local ec=$?
  # Remove lockfile only if we own it (PID matches $$)
  if [ -f "$LOCKFILE" ] && [ -n "$(cat "$LOCKFILE" 2>/dev/null)" ]; then
    if [ "$(cat "$LOCKFILE" 2>/dev/null)" = "$$" ]; then
      rm -f "$LOCKFILE"
      log "cleanup_on_exit: removed lockfile (we owned it)"
    fi
  fi
  # Kill any direct children that may have been spawned by this process
  # (e.g., bash -c commands from Claude's Bash tool that didn't get reaped)
  pkill -P $$ 2>/dev/null || true
  # Call the main cleanup function to remove temp files
  cleanup
  exit "$ec"
}
trap cleanup_on_exit EXIT INT TERM

# Note: EXIT trap is already set above. The cleanup function is still available for
# non-error exits (e.g., normal completion via exit 0 after verdict posted).
# When review succeeds, we want to skip lockfile removal since the verdict was posted.

# =============================================================================
# LOG ROTATION
# =============================================================================
if [ -f "$LOGFILE" ] && [ "$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
  mv "$LOGFILE" "$LOGFILE.old"
fi

# =============================================================================
# RESOLVE FORGE REMOTE FOR GIT OPERATIONS
# =============================================================================
resolve_forge_remote

# =============================================================================
# RESOLVE AGENT IDENTITY FOR .PROFILE REPO
# =============================================================================
resolve_agent_identity || true

# =============================================================================
# MEMORY GUARD
# =============================================================================
memory_guard 1500

# =============================================================================
# CONCURRENCY LOCK
# =============================================================================
if [ -f "$LOCKFILE" ]; then
  LPID=$(cat "$LOCKFILE" 2>/dev/null || true)
  [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null && { log "SKIP: locked"; exit 0; }
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"

# =============================================================================
# FETCH PR METADATA
# =============================================================================
status "fetching metadata"
PR_JSON=$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" "${API}/pulls/${PR_NUMBER}")
PR_TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title')
PR_BODY=$(printf '%s' "$PR_JSON" | jq -r '.body // ""')
PR_HEAD=$(printf '%s' "$PR_JSON" | jq -r '.head.ref')
PR_BASE=$(printf '%s' "$PR_JSON" | jq -r '.base.ref')
PR_SHA=$(printf '%s' "$PR_JSON" | jq -r '.head.sha')
PR_STATE=$(printf '%s' "$PR_JSON" | jq -r '.state')
log "${PR_TITLE} (${PR_HEAD}→${PR_BASE} ${PR_SHA:0:7})"

if [ "$PR_STATE" != "open" ]; then
  log "SKIP: state=${PR_STATE}"
  worktree_cleanup "$WORKTREE"
  rm -f "$OUTPUT_FILE" "$SID_FILE" 2>/dev/null || true
  rm -f "$LOCKFILE"
  exit 0
fi

# =============================================================================
# CI CHECK
# =============================================================================
CI_STATE=$(ci_commit_status "$PR_SHA")
CI_NOTE=""
# Gate only on required pipelines (#920). Optional/stuck workflows do not block.
if ! ci_required_passed "$PR_SHA"; then
  log "SKIP: required CI not green (CI=${CI_STATE})"
  rm -f "$LOCKFILE"
  exit 0
fi
if ! ci_passed "$CI_STATE"; then
  CI_NOTE=" (optional checks not green; required passed)"
fi

# =============================================================================
# DUPLICATE CHECK — skip if already reviewed at this SHA
# =============================================================================
ALL_COMMENTS=$(forge_api_all "/issues/${PR_NUMBER}/comments")
HAS_CMT=$(printf '%s' "$ALL_COMMENTS" | jq --arg s "$PR_SHA" \
  '[.[]|select(.body|contains("<!-- reviewed: "+$s+" -->"))]|length')
[ "${HAS_CMT:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: reviewed ${PR_SHA:0:7}"; rm -f "$LOCKFILE"; exit 0; }
HAS_FML=$(forge_api_all "/pulls/${PR_NUMBER}/reviews" | jq --arg s "$PR_SHA" \
  '[.[]|select(.commit_id==$s)|select(.state!="COMMENT")]|length')
[ "${HAS_FML:-0}" -gt 0 ] && [ "$FORCE" != "--force" ] && { log "SKIP: formal review"; rm -f "$LOCKFILE"; exit 0; }

# =============================================================================
# DIFF BLOCK ASSEMBLY (#1256)
# =============================================================================
# diff_block — assemble a "### <label>" prompt section for a diff file.
# At or under DIFF_THRESHOLD bytes the full diff is pasted (the common case —
# no extra round-trips). Above it, nothing is pasted: the agent already has
# read/bash and the worktree is checked out at the PR head, so it gets the
# worktree path + the exact git commands instead. A pasted 25KB diff can be
# auto-compacted away mid-review and lose file coverage (#1260); a worktree
# read survives compaction (#1256).
# Args: $1=label  $2=diff file  $3=git command that reproduces the diff
#       $4=ref of the pre-change content, to recover deleted files (may be "")
diff_block() {
  local label="$1" file="$2" local_cmd="$3" old_ref="${4:-}" size
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  if [ "$size" -le "$DIFF_THRESHOLD" ]; then
    printf '### %s\n```diff\n' "$label"
    cat "$file"
    printf '\n```'
    return 0
  fi
  printf '### %s (large: %s bytes — not pasted, read it locally)\n' "$label" "$size"
  printf 'The diff is larger than %s bytes, so it is NOT pasted here. The worktree at `%s` (your working directory) is checked out at the PR head (`%s`).\n' \
    "$DIFF_THRESHOLD" "$WORKTREE" "${PR_SHA:0:7}"
  printf '1. Full diff: `%s`\n' "$local_cmd"
  printf '2. Per file: `%s -- <path>`\n' "$local_cmd"
  [ -n "$old_ref" ] && printf '3. Old version of a file the PR deletes: `git -C %s show %s:<path>`\n' "$WORKTREE" "$old_ref"
  printf 'Read EVERY changed file listed under "Changed Files" above before judging — your verdict must cover all of them, not just the first ones you read.\n'
  return 0
}

# =============================================================================
# RE-REVIEW DETECTION
# =============================================================================
# Re-review context budget (#1257): prior review rounds are injected as
# compact digests — verdict + findings list per round, findings capped at
# DIGEST_CAP bytes — instead of full review bodies (the worst prompts in the
# system), and the incremental diff is bounded by diff_block at
# DIFF_THRESHOLD (12KB — the same number #1257 proposed for full diffs; #1256
# landed it first, so this reuses it). Findings in the posted review are list
# items (formula section 9), so each digest keeps every list line of its
# round: a 3rd-round re-review still sees every finding from every prior
# round (no dropped threads) while the prompt stays bounded.
# review_digest — compact digest of one prior review comment: its verdict
# line plus the findings list (list items + section headings of the review
# markdown), the list capped at DIGEST_CAP bytes with a truncation note.
# Arg: $1=review comment body
review_digest() {
  local body="$1" md verdict line selected kept="" n=0 lsz
  # Review markdown = the region between the "<!-- reviewed: -->" marker line
  # and the final "### Verdict" heading — the shape the orchestrator posts.
  md=$(printf '%s\n' "$body" | awk '
    /^<!-- reviewed: /{f=1; next}
    f && /^### Verdict[[:space:]]*$/{exit}
    f{print}')
  [ -n "$md" ] || md="$body"
  # Verdict = the line after the LAST "### Verdict" heading (ours, not one
  # the agent may have written inside its own markdown).
  verdict=$(printf '%s\n' "$body" | awk '
    /^### Verdict[[:space:]]*$/{ if ((getline) > 0) v=$0 }
    END{ print v }')
  [ -n "$verdict" ] || verdict="**VERDICT NOT CAPTURED**"
  # Findings = list items and section headings of the review markdown;
  # prose (summaries, explanations) is what the cap buys.
  selected=$(printf '%s\n' "$md" | grep -E \
    '^[[:space:]]*([-*][[:space:]]+|[0-9]+[.)][[:space:]]+|#{1,6}[[:space:]]+)' || true)
  kept="$verdict"$'\n'
  n=$(printf '%s\n' "$verdict" | wc -c | tr -d '[:space:]')
  if [ -n "$selected" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      lsz=$(printf '%s\n' "$line" | wc -c | tr -d '[:space:]')
      if [ "$(( n + lsz ))" -gt "$DIGEST_CAP" ]; then
        kept="${kept}… (findings truncated at ${DIGEST_CAP} bytes — full review body is on the PR)"$'\n'
        break
      fi
      kept="${kept}${line}"$'\n'
      n=$(( n + lsz ))
    done <<< "$selected"
  fi
  printf '%s' "$kept"
}

# build_re_review_context — detect prior review rounds and assemble the
# bounded re-review prompt section. Sets IS_RE_REVIEW, PREV_SHA, PREV_CONTEXT.
# Requires: ALL_COMMENTS PR_SHA PR_HEAD FORGE_REMOTE PROJECT_REPO_ROOT
#           REVIEW_TMPDIR WORKTREE (run from anywhere; cd's to the repo root
#   for the git fetch/diff, like the startup already does).
build_re_review_context() {
  local body rs_sha i prior_count last_idx prior_reviews fetch_err incr_file rounds dev_r dev_sec
  IS_RE_REVIEW=false
  PREV_SHA=""
  # Prior review rounds: every review comment not pinned to the current head
  # SHA, oldest first (API order). The most recent one anchors the
  # incremental diff; EVERY round gets a digest, so no round's findings are
  # dropped from the re-review prompt.
  prior_reviews=$(printf '%s' "$ALL_COMMENTS" | jq -c --arg s "$PR_SHA" \
    '[.[]|select(.body|contains("<!-- reviewed:"))|select(.body|contains($s)|not)]')
  prior_count=$(printf '%s' "$prior_reviews" | jq 'length' 2>/dev/null || echo 0)
  [ "${prior_count:-0}" -gt 0 ] || return 0
  last_idx=$(( prior_count - 1 ))
  PREV_SHA=$(printf '%s' "$prior_reviews" | jq -r ".[${last_idx}].body" \
    | grep -oP '<!-- reviewed: \K[a-f0-9]+' | head -1) || PREV_SHA=""
  cd "${PROJECT_REPO_ROOT}"
  fetch_err=$(git fetch "${FORGE_REMOTE}" "$PR_HEAD" 2>&1 >/dev/null) || \
    log "WARN: git fetch ${FORGE_REMOTE} ${PR_HEAD} failed: ${fetch_err} — incremental diff may be incomplete"
  incr_file="${REVIEW_TMPDIR}/incr.diff"
  git diff "${PREV_SHA}..${PR_SHA}" > "$incr_file" 2>/dev/null || true
  [ -s "$incr_file" ] || return 0
  IS_RE_REVIEW=true
  log "re-review: previous at ${PREV_SHA:0:7} (${prior_count} prior round(s))"
  rounds=""
  i=0
  while [ "$i" -lt "$prior_count" ]; do
    body=$(printf '%s' "$prior_reviews" | jq -r ".[${i}].body")
    rs_sha=$(printf '%s' "$body" | grep -oP '<!-- reviewed: \K[a-f0-9]+' | head -1) || rs_sha=""
    rounds="${rounds}### Round $(( i + 1 )) — reviewed \`${rs_sha:0:7}\`
$(review_digest "$body")

"
    i=$(( i + 1 ))
  done
  dev_r=$(printf '%s' "$ALL_COMMENTS" | jq -r \
    '[.[]|select(.body|contains("<!-- dev-response:"))]|last // empty')
  dev_sec=""
  [ -n "$dev_r" ] && [ "$dev_r" != "null" ] && \
    dev_sec=$(printf '\n### Developer Response\n%s' "$(printf '%s' "$dev_r" | jq -r '.body')") || true
  PREV_CONTEXT=$(printf '\n## This is a RE-REVIEW\n%s prior review round(s), compacted below — verdict + findings list per round (findings capped at %s bytes; the full review bodies are on the PR — fetch them via the PR comments API if a digest is truncated).\n%s%s%s' \
    "$prior_count" "$DIGEST_CAP" "$rounds" "$dev_sec" \
    "$(diff_block "Incremental Diff (${PREV_SHA:0:7}..${PR_SHA:0:7})" "$incr_file" \
      "git -C ${WORKTREE} diff ${PREV_SHA}..${PR_SHA}" "${PREV_SHA}")")
}
PREV_CONTEXT=""
build_re_review_context

# Recover session_id from .sid file (re-review continuity)
agent_recover_session

# =============================================================================
# FETCH DIFF
# =============================================================================
status "fetching diff"
curl -s -H "Authorization: token ${FORGE_TOKEN}" \
  "${API}/pulls/${PR_NUMBER}.diff" > "${REVIEW_TMPDIR}/full.diff"
FSIZE=$(stat -c%s "${REVIEW_TMPDIR}/full.diff" 2>/dev/null || echo 0)
FILES=$(grep -E '^\+\+\+ b/' "${REVIEW_TMPDIR}/full.diff" | sed 's|^+++ b/||' | grep -v '/dev/null' | sort -u || true)
# DIFF/DNOTE are assembled later (diff_block, #1256) once the worktree and
# merge-base are available.

# =============================================================================
# WORKTREE SETUP
# =============================================================================
# Fetch the PR head objects into this clone before checking them out. A
# swallowed fetch failure here made every review of an unfetched branch die
# with exit 128 and an unrelated message (#1075).
FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "$PR_HEAD" 2>&1 >/dev/null) || {
  log "WARN: git fetch ${FORGE_REMOTE} ${PR_HEAD} failed: ${FETCH_ERR}"
  # The PR head branch may have been deleted while the PR is still open;
  # retry by fetching the commit SHA directly.
  FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "$PR_SHA" 2>&1 >/dev/null) || \
    log "WARN: git fetch ${FORGE_REMOTE} ${PR_SHA} failed: ${FETCH_ERR}"
}

if ! git cat-file -e "${PR_SHA}^{commit}" 2>/dev/null; then
  # Objects are still missing. Record a review error naming the SHA so the
  # poll's error counter backs off instead of retrying blind (#1075).
  log "ERROR: objects for ${PR_SHA} missing after git fetch ${FORGE_REMOTE} (${FETCH_ERR})"
  jq -n --arg b "## AI Review — Error\n<!-- review-error: ${PR_SHA} -->\nReview failed: cannot fetch objects for \`${PR_SHA:0:7}\` from remote \`${FORGE_REMOTE}\` (head ref \`${PR_HEAD}\`). Both \`git fetch ${FORGE_REMOTE} ${PR_HEAD}\` and \`git fetch ${FORGE_REMOTE} ${PR_SHA}\` failed.\n---\n*${PR_SHA:0:7}*" \
    '{body: $b}' | curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" "${API}/issues/${PR_NUMBER}/comments" -d @- || true
  echo "ERROR: git fetch ${FORGE_REMOTE} ${PR_HEAD}/${PR_SHA} failed — objects for ${PR_SHA} missing, cannot check out"
  exit 128
fi

if [ -d "$WORKTREE" ]; then
  CO_ERR=$(cd "$WORKTREE" && git checkout --detach "$PR_SHA" 2>&1 >/dev/null) || {
    log "git checkout --detach ${PR_SHA} failed in existing worktree (${CO_ERR}); recreating"
    worktree_cleanup "$WORKTREE"
  }
fi
if [ ! -d "$WORKTREE" ]; then
  # A registration can outlive the worktree directory (a container restart
  # wiped this container's /tmp while the shared clone kept the record), in
  # which case `git worktree add` fails with "missing, but already registered"
  # and blocks every future review of this PR (#1082). Clear only this
  # path's stale registration before claiming it — never a blanket prune,
  # since the clone also registers live worktrees of other containers.
  worktree_clear_stale "$WORKTREE"
  WT_ERR=$(git worktree add "$WORKTREE" "$PR_SHA" --detach 2>&1 >/dev/null) || {
    log "ERROR: git worktree add ${WORKTREE} ${PR_SHA} --detach failed: ${WT_ERR}"
    # Record a review error naming the SHA so the poll's circuit breaker
    # backs off after N identical failures instead of retrying silently
    # forever (#1082).
    WT_MSG=$(printf '## AI Review — Error\n<!-- review-error: %s -->\nReview failed: could not create the review worktree at `%s` for `%s`.\n```\n%s\n```\n---\n*%s*' \
      "$PR_SHA" "$WORKTREE" "${PR_SHA:0:7}" "$WT_ERR" "${PR_SHA:0:7}")
    jq -n --arg b "$WT_MSG" '{body: $b}' | curl -sf -o /dev/null -X POST \
      -H "Authorization: token ${FORGE_TOKEN}" -H "Content-Type: application/json" \
      "${API}/issues/${PR_NUMBER}/comments" -d @- || true
    echo "ERROR: git worktree add failed to check out ${PR_SHA}: ${WT_ERR}"
    exit 128
  }
fi

# Fetch the PR's base ref and compute the merge-base: the anchor for the
# local `git diff` that reproduces the forge PR diff when the diff is too
# large to paste (#1256). Unavailable base (deleted branch) is tolerated —
# the prompt falls back to the old truncated paste.
BASE_FETCH_ERR=$(git fetch "${FORGE_REMOTE}" "${PR_BASE}" 2>&1 >/dev/null) || \
  log "WARN: git fetch ${FORGE_REMOTE} ${PR_BASE} failed: ${BASE_FETCH_ERR}"
PR_MERGE_BASE=$(git merge-base "${FORGE_REMOTE}/${PR_BASE}" "$PR_SHA" 2>/dev/null || true)
[ -n "$PR_MERGE_BASE" ] || log "WARN: merge-base for ${PR_BASE} unavailable — falling back to pasted diff"

# =============================================================================
# STALE-BASE REGRESSION CHECK (#896)
# =============================================================================
# Detect PRs whose merged result will silently revert upstream changes that
# landed on main since the PR's base. The forward (head vs base) diff would
# look correct, so review-bot's normal pass would miss this.
status "checking stale-base regressions"
STALE_BASE_SECTION=""
git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
STALE_MAIN_REF="${FORGE_REMOTE}/${PRIMARY_BRANCH}"
STALE_OUTPUT=$(stale_base_check "$PR_SHA" "$STALE_MAIN_REF" 2>/dev/null || true)
if [ -n "$STALE_OUTPUT" ]; then
  STALE_LIST=$(stale_base_check_format "$STALE_OUTPUT")
  STALE_BASE_SECTION=$(printf '\n## Stale-base regression check (BLOCKER)\n\nThis PR is based on a stale main. After merge, the following files would be left missing lines that landed upstream since the PR'\''s merge-base:\n\n%s\n\nUnless the PR description explicitly states these reverts are intentional, you MUST set verdict=REQUEST_CHANGES and instruct the author to rebase on main and re-resolve. Reference issue #896.\n' "$STALE_LIST")
  log "stale-base regression detected: $(printf '%s' "$STALE_OUTPUT" | tr '\n' ' ')"
else
  log "stale-base check: no regressions"
fi

# =============================================================================
# PREPARE REVIEW
# =============================================================================
# (The per-PR structural-graph step was removed in #1258: the project root
# holds no objective/prerequisite sources — they live in the ops repo — so
# the report carried no PR-relevant content, and the review formula never
# referenced the section; in-container it was a ~527B stub of boilerplate.)
status "preparing review"

# =============================================================================
# LOAD LESSONS FROM .PROFILE REPO (PRE-SESSION)
# =============================================================================
formula_prepare_profile_context

# =============================================================================
# BUILD PROMPT
# =============================================================================
FORMULA=$(cat "${FACTORY_ROOT}/formulas/review-pr.toml")
# Diff section (#1256): small diffs are pasted in full (the common case, no
# extra round-trips); large diffs are referenced from the worktree instead,
# so the file list + local-read instructions survive auto-compaction. The
# old truncated paste remains only when the merge-base is unavailable.
if [ -n "$PR_MERGE_BASE" ]; then
  DIFF_SECTION=$(diff_block "Diff" "${REVIEW_TMPDIR}/full.diff" \
    "git -C ${WORKTREE} diff ${PR_MERGE_BASE}..HEAD" "$PR_MERGE_BASE")
else
  DIFF=$(head -c "$MAX_DIFF" "${REVIEW_TMPDIR}/full.diff")
  DNOTE=""; [ "$FSIZE" -gt "$MAX_DIFF" ] && DNOTE=" (truncated from ${FSIZE} bytes)"
  DIFF_SECTION=$(printf '### Diff%s\n```diff\n%s\n```' "$DNOTE" "$DIFF")
fi
{
  printf 'You are the review agent for %s. Follow the formula to review PR #%s.\n\n' \
    "${FORGE_REPO}" "${PR_NUMBER}"
  printf '## PR Context\n**%s** (%s → %s) | SHA: %s | CI: %s%s\nRe-review: %s\n\n' \
    "$PR_TITLE" "$PR_HEAD" "$PR_BASE" "$PR_SHA" "$CI_STATE" "$CI_NOTE" "$IS_RE_REVIEW"
  printf '### Description\n%s\n\n### Changed Files\n%s\n\n%s\n\n' \
    "$PR_BODY" "$FILES" "$DIFF_SECTION"
  [ -n "$PREV_CONTEXT" ] && printf '%s\n' "$PREV_CONTEXT"
  [ -n "$STALE_BASE_SECTION" ] && printf '%s\n' "$STALE_BASE_SECTION"
  formula_lessons_block
  printf '\n## Formula\n%s\n\n## Environment\nREVIEW_OUTPUT_FILE=%s\nFORGE_API=%s\nPR_NUMBER=%s\nFACTORY_ROOT=%s\nREVIEW_WORKTREE=%s\n' \
    "$FORMULA" "$OUTPUT_FILE" "$API" "$PR_NUMBER" "$FACTORY_ROOT" "$WORKTREE"
  printf 'NEVER echo the actual token — always reference ${FORGE_TOKEN} or ${FORGE_REVIEW_TOKEN}.\n'
  printf '\n## Completion\nAfter writing the JSON file to REVIEW_OUTPUT_FILE (%s), stop.\nDo NOT write to any phase file — completion is automatic.\n' "$OUTPUT_FILE"
} > "${REVIEW_TMPDIR}/prompt.md"
PROMPT=$(cat "${REVIEW_TMPDIR}/prompt.md")

# =============================================================================
# RUN REVIEW AGENT + PARSE OUTPUT
# =============================================================================
# review_run_and_parse() — run the review agent and parse its verdict.
# The agent_run calls are guarded (`|| REVIEW_RUN_RC=$?`): a session that
# hits its resource limit (rc 124 = wall-clock timeout) must NOT abort this
# script under set -e — the run's rc is recorded instead, and the no-output
# path below posts the "Review failed" comment with the reason so a timed-out
# review is visible on the PR rather than a silent hang (#1164).
# Returns 0 on valid output (REVIEW_JSON set), 1 after posting the error
# comment.
review_run_and_parse() {
  local raw="" ext="" rc_note=""
  REVIEW_RUN_RC=0
  status "running review"
  rm -f "$OUTPUT_FILE"
  # Review-specific overrides, distinct from the container's values: the jobspec
  # sets CLAUDE_MODEL deliberately (Claude Code sizes its context window from
  # the name, so it must match the served model) and CLAUDE_TIMEOUT carries the
  # dev budget (7200) — a fallback that inherited it would never apply the cap.
  export CLAUDE_MODEL="${REVIEW_CLAUDE_MODEL:-$CLAUDE_MODEL}"
  export CLAUDE_TIMEOUT="${REVIEW_CLAUDE_TIMEOUT:-3600}"   # 60 min — dsh reviews on the shared llama box need headroom under contention (25KB+ fixed prompt overhead prefills slowly); a review still running at 60 min is stuck, not thorough
  # dsh agents need output paths in-process: formulas/review-pr.toml section 9
  # uses shell expansion ("> $REVIEW_OUTPUT_FILE"), and without the export the
  # agent guesses a path and the verdict is lost (#1230 wrote
  # /tmp/disinto-review-1230.json instead of the file below).
  export REVIEW_OUTPUT_FILE="$OUTPUT_FILE"
  # Tech-debt filing contract (formula section 7) shells out with
  # $FORGE_TOKEN/$FORGE_API. dsh inherits parent env, but pin these
  # explicitly: without them the agent cannot file follow-up issues and
  # the auto-file loop silently degrades to pasted suggestions (#1239).
  export FORGE_TOKEN FORGE_API
  if [ "$IS_RE_REVIEW" = true ] && [ -n "$_AGENT_SESSION_ID" ]; then
    agent_run --resume "$_AGENT_SESSION_ID" --worktree "$WORKTREE" --task "$PR_NUMBER" "$PROMPT" || REVIEW_RUN_RC=$?
  else
    agent_run --worktree "$WORKTREE" --task "$PR_NUMBER" "$PROMPT" || REVIEW_RUN_RC=$?
  fi
  if [ "$REVIEW_RUN_RC" -ne 0 ]; then
    log "agent_run exited ${REVIEW_RUN_RC} (re-review: ${IS_RE_REVIEW})"
  else
    log "agent_run complete (re-review: ${IS_RE_REVIEW})"
  fi

  REVIEW_JSON=""
  if [ -f "$OUTPUT_FILE" ]; then
    raw=$(cat "$OUTPUT_FILE")
    if printf '%s' "$raw" | jq -e '.verdict' >/dev/null 2>&1; then REVIEW_JSON="$raw"
    else
      ext=$(printf '%s' "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
      [ -z "$ext" ] && ext=$(printf '%s' "$raw" | sed -n '/^{/,/^}/p')
      [ -n "${ext:-}" ] && printf '%s' "$ext" | jq -e '.verdict' >/dev/null 2>&1 && REVIEW_JSON="$ext"
    fi
  fi

  if [ -z "$REVIEW_JSON" ]; then
    case "$REVIEW_RUN_RC" in
      124) rc_note=" (review timed out after ${CLAUDE_TIMEOUT}s — agent_run rc 124)" ;;
      0) rc_note="" ;;
      *) rc_note=" (agent_run rc ${REVIEW_RUN_RC})" ;;
    esac
    log "ERROR: no valid review output${rc_note}"
    jq -n --arg b "## AI Review — Error\n<!-- review-error: ${PR_SHA} -->\nReview failed${rc_note}.\n---\n*${PR_SHA:0:7}*" \
      '{body: $b}' | curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" "${API}/issues/${PR_NUMBER}/comments" -d @- || true
    return 1
  fi
  return 0
}

if ! review_run_and_parse; then
  exit 1
fi

VERDICT=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict' | tr '[:lower:]' '[:upper:]' | tr '-' '_')
REASON=$(printf '%s' "$REVIEW_JSON" | jq -r '.verdict_reason // ""')
REVIEW_MD=$(printf '%s' "$REVIEW_JSON" | jq -r '.review_markdown // ""')
log "verdict: ${VERDICT}"

# =============================================================================
# POST REVIEW
# =============================================================================
status "posting review"
RTYPE="Review"
if [ "$IS_RE_REVIEW" = true ]; then
  RTYPE="Re-review (round $(($(printf '%s' "$ALL_COMMENTS" | \
    jq '[.[]|select(.body|contains("<!-- reviewed:"))]|length') + 1)))"
fi
PREV_REF=""; [ "$IS_RE_REVIEW" = true ] && PREV_REF=$(printf ' | Previous: `%s`' "${PREV_SHA:0:7}") || true
COMMENT_BODY=$(printf '## AI %s\n<!-- reviewed: %s -->\n\n%s\n\n### Verdict\n**%s** — %s\n\n---\n*Reviewed at `%s`%s | [AGENTS.md](AGENTS.md)*' \
  "$RTYPE" "$PR_SHA" "$REVIEW_MD" "$VERDICT" "$REASON" "${PR_SHA:0:7}" "$PREV_REF")
printf '%s' "$COMMENT_BODY" > "${REVIEW_TMPDIR}/body.txt"
jq -Rs '{body: .}' < "${REVIEW_TMPDIR}/body.txt" > "${REVIEW_TMPDIR}/comment.json"
POST_RC=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: token ${FORGE_REVIEW_TOKEN}" -H "Content-Type: application/json" \
  "${API}/issues/${PR_NUMBER}/comments" --data-binary @"${REVIEW_TMPDIR}/comment.json")
[ "$POST_RC" != "201" ] && { log "ERROR: comment HTTP ${POST_RC}"; exit 1; }
log "posted review comment"

# =============================================================================
# POST FORMAL REVIEW
# =============================================================================
REVENT="COMMENT"
case "$VERDICT" in APPROVE) REVENT="APPROVED" ;; REQUEST_CHANGES|DISCUSS) REVENT="REQUEST_CHANGES" ;; esac
if [ "$REVENT" = "APPROVED" ]; then
  BLOGIN=$(curl -sf -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
    "${API%%/repos*}/user" 2>/dev/null | jq -r '.login // empty' || true)
  [ -n "$BLOGIN" ] && forge_api_all "/pulls/${PR_NUMBER}/reviews" "${FORGE_REVIEW_TOKEN}" 2>/dev/null | \
    jq -r --arg l "$BLOGIN" '.[]|select(.state=="REQUEST_CHANGES")|select(.user.login==$l)|.id' | \
    while IFS= read -r rid; do
      curl -sf -o /dev/null -X POST -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
        -H "Content-Type: application/json" "${API}/pulls/${PR_NUMBER}/reviews/${rid}/dismissals" \
        -d '{"message":"Superseded by approval"}' || true; log "dismissed review ${rid}"
    done || true
fi
jq -n --arg b "AI ${RTYPE}: **${VERDICT}** — ${REASON}" --arg e "$REVENT" --arg s "$PR_SHA" \
  '{body: $b, event: $e, commit_id: $s}' > "${REVIEW_TMPDIR}/formal.json"
curl -s -o /dev/null -X POST -H "Authorization: token ${FORGE_REVIEW_TOKEN}" \
  -H "Content-Type: application/json" "${API}/pulls/${PR_NUMBER}/reviews" \
  --data-binary @"${REVIEW_TMPDIR}/formal.json" >/dev/null 2>&1 || true
log "formal ${REVENT} submitted"

# =============================================================================
# FINAL CLEANUP
# =============================================================================
case "$VERDICT" in
  REQUEST_CHANGES|DISCUSS)
    # Keep session and worktree for re-review continuity
    log "keeping session for re-review (SID: ${_AGENT_SESSION_ID:0:12}...)"
    ;;
  *)
    rm -f "$SID_FILE" "$OUTPUT_FILE"
    worktree_cleanup "$WORKTREE"
    ;;
esac

# Write journal entry post-session
profile_write_journal "review-${PR_NUMBER}" "Review PR #${PR_NUMBER} (${VERDICT})" "${VERDICT,,}" "" || true

log "DONE: ${VERDICT} (re-review: ${IS_RE_REVIEW})"

# Remove lockfile on successful completion (cleanup_on_exit will also do this,
# but we do it here to avoid the trap running twice)
rm -f "$LOCKFILE"
