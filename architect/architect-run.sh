#!/usr/bin/env bash
# =============================================================================
# architect-run.sh — Forgejo-state-driven architect lifecycle
#
# Bash-driven state machine operating on architect PRs on the ops repo.
# No tmux sessions, no phase files — the bash script IS the state machine.
#
# Lifecycle states:
#   [decompose] — the PR adds sprints/<slug>.md; on its branch the file has a
#     sprint block and no sub-issue entries and architect-bot has not yet
#     commented. The architect drafts the sub-issues once (#1910).
#   [q_and_a] — PR open, new non-architect comment since last-seen marker.
#     The session revises the committed sub-issue draft; bash commits and
#     posts the reply (#1911).
#
# Round-robin: PRs sorted by <!-- architect-last-seen: <iso> --> ascending;
# head of queue is picked each iteration. The last-seen marker is not advanced after a failed dispatch (_OPUS_DISPATCH_FAILED); a failed dispatch leaves the marker, so the same PR is retried next cycle.
# A formula-load failure and a failed reply POST set that flag too. The unsent
# reply is stashed under /tmp (with that cycle's timestamp) and reposted next
# cycle — including when the pitch commit already landed and when architect-bot
# has already commented something else — without a PR-body patch (a patch would
# bump updated_at and send the PR to the back of the queue). A successful
# repost moves last-seen to the failed cycle's timestamp, not to now, so an
# owner comment that arrived during the retry stays visible.
#
# Write-permission contract:
#   ops repo: PATCH PR body, POST comments, close PR, commit the pitch file to the PR branch through the contents API (`pitch_pr_put` in `lib/pitch-pr.sh`, as `architect-bot`) when drafting or revising sub-issues. It never merges.
#   project repo: NONE (only reads — issues, acceptance scripts, vision)
#
# Formula (#1335): the architect always uses formulas/run-architect.toml —
# oak instances differ by pack, not kind, so research boxes run the
# software formula.
#
# Usage:
#   architect-run.sh [projects/disinto.toml]
#
# Called by: entrypoint.sh polling loop (every 15 min by default)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FACTORY_ROOT="$(dirname "$SCRIPT_DIR")"

export PROJECT_TOML="${1:-$FACTORY_ROOT/projects/disinto.toml}"
export FORGE_TOKEN_OVERRIDE="${FORGE_ARCHITECT_TOKEN:-}"

source "$FACTORY_ROOT/lib/env.sh"
source "$FACTORY_ROOT/lib/formula-session.sh"
source "$FACTORY_ROOT/lib/worktree.sh"
source "$FACTORY_ROOT/lib/guard.sh"
source "$FACTORY_ROOT/lib/agent-sdk.sh"
source "$FACTORY_ROOT/lib/pitch.sh"
source "$FACTORY_ROOT/lib/pitch-pr.sh"

LOG_FILE="${DISINTO_LOG_DIR}/architect/architect.log"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh
LOGFILE="$LOG_FILE"
# shellcheck disable=SC2034  # consumed by agent-sdk.sh / agent-harness-dsh.sh
SID_FILE="/tmp/architect-session-${PROJECT_NAME}.sid"
LOG_AGENT="architect"

log() {
  local agent="${LOG_AGENT:-architect}"
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$agent" "$*" >> "$LOG_FILE"
}

# ── Guards ────────────────────────────────────────────────────────────────
check_active architect
acquire_run_lock "/tmp/architect-run.lock"
memory_guard 2000

log "--- Architect run start ---"

# ── Scratch worktree ──────────────────────────────────────────────────────
WORKTREE="/tmp/${PROJECT_NAME}-architect-run"

# Cleanup worktree (and claude cache) on exit so re-runs get a fresh checkout
trap 'worktree_cleanup "$WORKTREE" 2>/dev/null || true' EXIT

cd "$PROJECT_REPO_ROOT"
if [ -z "${FORGE_REMOTE:-}" ]; then
  resolve_forge_remote
fi
git fetch "${FORGE_REMOTE}" "${PRIMARY_BRANCH}" 2>/dev/null || true
worktree_cleanup "$WORKTREE" 2>/dev/null || true
git worktree add "$WORKTREE" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" --detach 2>/dev/null || {
  log "WARNING: worktree add failed — q_and_a opus dispatch will fail"
}

# ── Resolve agent identity ──────────────────────────────────────────────
if [ -z "${AGENT_IDENTITY:-}" ] && [ -n "${FORGE_ARCHITECT_TOKEN:-}" ]; then
  AGENT_IDENTITY=$(forge_whoami)
fi

# ARCHITECT_LOGIN — the Forgejo identity that posts the architect's own
# comments. Engagement checks exclude it, so a posted reply does not re-wake
# the agent (reply loop, once per ARCHITECT_INTERVAL). #1910 uses
# architect_has_commented to detect it.
ARCHITECT_LOGIN="${AGENT_IDENTITY:-architect-bot}"

# ── Formula (#1335) ──────────────────────────────────────────────────────
# The architect always uses formulas/run-architect.toml — the kind
# selection from #1315 is gone: oak instances differ by pack, not kind,
# so research boxes run the software formula.
architect_formula_file() {
  echo "$FACTORY_ROOT/formulas/run-architect.toml"
}
ARCHITECT_FORMULA="$(architect_formula_file)"

# Role text for the opus prompts: the decomposition target is development
# sprints and the filed sub-issues are backlog sub-issues.
PITCH_NOUN="sprint"
SUBISSUE_TERM="sub-issues"
QA_ROLE_TEXT="Your role: draft and revise the sub-issues of sprint pitches (ops-repo PRs that add sprints/<slug>.md). You never file, merge or close: the owner's merge is the decision."
log "architect formula: ${ARCHITECT_FORMULA##*/}"

# ── Forgejo API helpers ─────────────────────────────────────────────────
# All writes target ${FORGE_OPS_REPO} only.

# fetch_open_architect_prs — JSON array of architect PR objects
fetch_open_architect_prs() {
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls?state=open&limit=100" 2>/dev/null || echo '[]'
}

# get_pr_body <pr_number> — PR body text
get_pr_body() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" 2>/dev/null \
    | jq -r '.body // empty' 2>/dev/null || echo ""
}

# get_pr_comments <pr_number> — JSON array of comment objects
get_pr_comments() {
  local pr="$1"
  curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr}/comments" 2>/dev/null || echo '[]'
}

# others_comments_since <pr_number> <since_iso> — JSON array of the comments
# from get_pr_comments newer than SINCE and not by the architect
# ((.user.login // "") != ARCHITECT_LOGIN). The since-filter + architect
# exclusion live here so the state predicates read the filtered array instead
# of re-filtering get_pr_comments themselves.
others_comments_since() {
  local pr="$1" since="$2"
  printf '%s' "$(get_pr_comments "$pr")" | jq -c \
    --arg since "$since" \
    --arg me "$ARCHITECT_LOGIN" \
    '[(.[]
      | select(.updated_at > $since)
      | select((.user.login // "") != $me))]'
}

# has_reject_comment <pr_number> <since_iso> — 0 if Reject: comment since marker
# (by anyone other than the architect, via others_comments_since)
has_reject_comment() {
  local pr="$1" since="$2"
  # Extract the non-architect comments since the marker and check for Reject: prefix
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[]
  ' 2>/dev/null | grep -q '^Reject:' 2>/dev/null
}

# get_reject_reason <pr_number> <since_iso> — the reason after "Reject: "
# (from a non-architect comment since the marker, via others_comments_since)
get_reject_reason() {
  local pr="$1" since="$2"
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[] | select(startswith("Reject:"))
  ' 2>/dev/null | head -1 | sed 's/^Reject: *//' 2>/dev/null || echo "rejected"
}

# has_new_comment_since <pr_number> <since_iso> — 0 if non-reject comment exists
# (by anyone other than the architect since the marker, via others_comments_since)
has_new_comment_since() {
  local pr="$1" since="$2"
  # Check for any non-architect comment newer than last-seen that is NOT a Reject:
  printf '%s' "$(others_comments_since "$pr" "$since")" | jq -r '
    [.[] | .body] | .[] | select(test("^Reject:") | not)
  ' 2>/dev/null | head -1 | grep -q . 2>/dev/null
}

# architect_has_commented <pr_number> — 0 if a comment of get_pr_comments
# carries .user.login == ARCHITECT_LOGIN, 1 otherwise. #1910 uses it to
# decide whether a pitch already has an architect reply on the thread.
architect_has_commented() {
  local pr="$1"
  printf '%s' "$(get_pr_comments "$pr")" | jq -e \
    --arg me "$ARCHITECT_LOGIN" \
    'any(.[]; (.user.login // "") == $me)' >/dev/null 2>&1
}

# post_pr_comment <pr_number> <body> — POST a comment
post_pr_comment() {
  local pr="$1" body="$2"
  curl -sf -X POST \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/issues/${pr}/comments" \
    -d "{\"body\":$(printf '%s' "$body" | jq -Rs '.')} " 2>/dev/null
}

# patch_pr_body <pr_number> <new_body> — PATCH the PR body
patch_pr_body() {
  local pr="$1" body="$2"
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" \
    -d "{\"body\":$(printf '%s' "$body" | jq -Rs '.')} " 2>/dev/null
}

# close_pr <pr_number> — close the PR with a comment
close_pr() {
  local pr="$1" reason="$2"
  post_pr_comment "$pr" "Rejected: ${reason}" 2>/dev/null || true
  curl -sf -X PATCH \
    -H "Authorization: token ${FORGE_TOKEN}" \
    -H "Content-Type: application/json" \
    "${FORGE_API_BASE}/repos/${FORGE_OPS_REPO}/pulls/${pr}" \
    -d '{"state":"closed"}' 2>/dev/null || true
}

# ── PR body marker helpers ──────────────────────────────────────────────

# extract_last_seen <pr_body> — extract <!-- architect-last-seen: ... -->
extract_last_seen() {
  printf '%s' "$1" | grep -oP '<!-- architect-last-seen:\s*\K[^ ]+' 2>/dev/null || echo ""
}

# update_last_seen <pr_body> <new_iso> — replace last-seen marker
update_last_seen() {
  local body="$1" new_iso="$2"
  if printf '%s' "$body" | grep -q '<!-- architect-last-seen:'; then
    printf '%s' "$body" | sed "s|<!-- architect-last-seen: *[^ ]* -->|<!-- architect-last-seen: ${new_iso} -->|"
  else
    printf '%s\n%s' "$body" "<!-- architect-last-seen: ${new_iso} -->"
  fi
}

# pending_reply_path PR — file holding a reply whose POST failed.
# Not a lifecycle phase: the forge thread is the record. The file only keeps
# the unsent body so the next cycle can repost it without patching the PR
# (a patch would bump updated_at). Format: first line is the failed cycle's
# NOW_ISO, the rest is the comment body. publish_draft writes the same path
# and shape when pending_reply_path is not in scope (an extracted copy).
pending_reply_path() {
  printf '/tmp/architect-pending-reply-%s-%s' "${PROJECT_NAME:-architect}" "$1"
}

# read_pending_seen PR — the failed cycle's timestamp, or nothing.
read_pending_seen() {
  local path line
  path="$(pending_reply_path "$1")"
  [ -s "$path" ] || return 0
  IFS= read -r line <"$path" || true
  printf '%s' "$line"
}

# read_pending_reply PR — the stashed comment body, or nothing.
read_pending_reply() {
  local path
  path="$(pending_reply_path "$1")"
  [ -s "$path" ] || return 0
  tail -n +2 "$path"
}

# clear_pending_reply PR — drop the stash after the reply is on the thread.
clear_pending_reply() {
  rm -f "$(pending_reply_path "$1")"
}

# pending_reply_already_posted PR BODY — 0 when some architect comment's body
# equals BODY after trailing newlines are stripped. A different architect
# comment does not count: the first draft's reply must not swallow a later
# revision whose POST failed (#1962).
pending_reply_already_posted() {
  local pr="$1" want="$2"
  want="${want%"${want##*[!$'\n']}"}"
  [ -n "$want" ] || return 1
  printf '%s' "$(get_pr_comments "$pr")" | jq -e \
    --arg me "${ARCHITECT_LOGIN:-}" \
    --arg want "$want" \
    'any(.[];
      (.user.login // "") == $me
      and ((.body // "") | sub("\n+$"; "")) == $want)' >/dev/null 2>&1
}

# ── Round-robin: list and sort PRs by last-seen marker ─────────────────

list_architect_prs_sorted() {
  local prs
  prs=$(fetch_open_architect_prs)

  # Extract PR number and last-seen timestamp, sort by timestamp ascending
  printf '%s' "$prs" | jq -r '.[] | select(.title | startswith("architect:")) |
    "\(.number)|\(.updated_at)"' 2>/dev/null | sort -t'|' -k2 || true
}

# ── State: q_and_a ──────────────────────────────────────────────────────
# PR open, new non-architect comments since last-seen.
# Reject branch: bash-only (close PR). Otherwise: a session revises the
# committed sub-issue draft; bash commits and posts the reply (#1911).

dispatch_q_and_a() {
  local pr="$1" body="$2" last_seen="$3"

  # Check for Reject: comment
  if has_reject_comment "$pr" "$last_seen"; then
    local reason
    reason=$(get_reject_reason "$pr" "$last_seen")
    log "PR #${pr}: REJECT detected — closing PR"
    close_pr "$pr" "$reason"
    return
  fi

  # Check for new non-reject comments (engagement signal)
  if has_new_comment_since "$pr" "$last_seen"; then
    log "PR #${pr}: new engagement detected — dispatching opus session"
    _dispatch_opus_qa "$pr" "$body" "$last_seen"
    return
  fi

  log "PR #${pr}: no new engagement — idle"
}

# _dispatch_opus_qa PR BODY SINCE — revise the committed draft on the owner's
# comments. prepare_pitch stages the pitch file, the open backlog and the reply
# file; the session rewrites the filer block (or drafts it) and writes the reply
# to COMMENT_FILE. Bash commits a changed file and posts the reply with the lint
# report via publish_draft, as in decompose. A PR that is not a pitch is logged
# and skipped (return 0) — the session never posts or merges.
_dispatch_opus_qa() {
  local pr="$1" body="$2" since="$3"
  # BODY stays in the signature (dispatch_q_and_a passes the PR body) but the
  # session reads the pitch file on the PR branch, not the PR body.
  : "$body"

  if ! prepare_pitch "$pr"; then
    log "PR #${pr} is not a pitch"
    return 0
  fi

  # Load formula + context for the opus session. A load failure must hold
  # last-seen: the caller's `|| true` would otherwise advance the marker and
  # others_comments_since would drop the owner's comment.
  if ! load_formula_or_profile "architect" "$ARCHITECT_FORMULA"; then
    log "PR #${pr}: formula load failed — holding last-seen"
    _OPUS_DISPATCH_FAILED=true
    return 1
  fi
  build_context_block VISION.md AGENTS.md ops:prerequisites.md
  formula_prepare_profile_context
  build_graph_section

  SCRATCH_CONTEXT=$(read_scratch_context "/tmp/architect-${PROJECT_NAME}-scratch.md")
  SCRATCH_INSTRUCTION=$(build_scratch_instruction "/tmp/architect-${PROJECT_NAME}-scratch.md")
  build_sdk_prompt_footer

  local new_comments
  new_comments="$(others_comments_since "$pr" "$since" | jq -r '.[] | "**\(.user.login)**: \(.body)"')"

  local prompt
  prompt=$(cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

${QA_ROLE_TEXT}
DO NOT create issues, PRs, or any other resource on the project repo.
If you think ${SUBISSUE_TERM} should be filed, write them into the ${PITCH_NOUN} file's
filer:begin block only. You do not have permission to POST to the project repo and
any such call will return 403 and fail this run.

## CURRENT STATE: Design Q&A: revise the sub-issues

PITCH_FILE=${PITCH_FILE}
BACKLOG_FILE=${BACKLOG_FILE}
COMMENT_FILE=${COMMENT_FILE}

### New comments
${new_comments}

1. Read the new comments. 2. Revise the sub-issue block in PITCH_FILE as they ask, or draft it if there is none (formula steps ground, draft, lint). 3. Write your reply to COMMENT_FILE (formula step reply). Do not post it, and do not close or merge the PR.

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
$(formula_lessons_block)
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}
_PROMPT_EOF_
  )

  # Run opus session
  agent_run --worktree "$WORKTREE" "$prompt" || {
    log "PR #${pr}: opus q_and_a FAILED (exit $?)"
    _OPUS_DISPATCH_FAILED=true
    return 1
  }
  log "opus q_and_a session complete"
  publish_draft "$pr" "architect: revise sub-issues"
}

# ── Decompose (#1910) ───────────────────────────────────────────────────
#
# A pitch that carries only its goal and its sprint block (#1887) still has no
# sub-issue entries. This state decomposes the pitch: a session (formula steps
# ground, draft, lint, reply) writes the `## Sub-issues` block into a local copy,
# bash commits the changed file to the PR branch through the contents API as
# architect-bot, and posts the reply with the pitch-lint report. It never merges
# or files: the owner's merge is the decision (#1907). There is no tape record:
# an undecided pitch serves no proposal (docs/design/proposal-loop.md §3).

# prepare_pitch PR — stage the decompose state for PR: fetch the pitch file as
# it stands on the PR branch to PITCH_FILE, keep a pristine copy in
# $PITCH_DIR/orig, and write the (empty) backlog JSON and reply file. Returns
# 1 when the pitch path or the fetch is missing.
prepare_pitch() {
  local pr="$1"
  PITCH_PATH="$(pitch_pr_path "$pr" 2>/dev/null)" || return 1
  [ -n "$PITCH_PATH" ] || return 1
  PITCH_DIR="/tmp/architect-pitch-${pr}"
  rm -rf "$PITCH_DIR"
  mkdir -p "$PITCH_DIR" || return 1
  PITCH_FILE="$PITCH_DIR/$(basename -- "$PITCH_PATH")"
  if ! read -r PITCH_BRANCH PITCH_SHA < <(pitch_pr_fetch "$pr" "$PITCH_PATH" "$PITCH_FILE" 2>/dev/null); then
    return 1
  fi
  [ -n "$PITCH_BRANCH" ] || return 1
  cp "$PITCH_FILE" "$PITCH_DIR/orig" || return 1
  BACKLOG_FILE="$PITCH_DIR/backlog.json"
  forge_api_all "/issues?state=open&type=issues&labels=backlog" >"$BACKLOG_FILE" 2>/dev/null
  jq -e 'type == "array"' "$BACKLOG_FILE" >/dev/null 2>&1 || printf '[]' >"$BACKLOG_FILE"
  COMMENT_FILE="$PITCH_DIR/comment.md"
  printf '' >"$COMMENT_FILE"
  log "PR #${pr}: prepared pitch $PITCH_PATH at $PITCH_FILE"
  return 0
}

# pitch_has_entries FILE — 0 when a line starting "- id:" lies between the
# <!-- filer:begin --> and <!-- filer:end --> markers in FILE. This is the
# decompose gate: a pitch with only its goal and sprint block carries no
# sub-issue entries, and this gate fires the decompose branch once on such a
# pitch (the owner's comments then drive the revisions, #1911).
pitch_has_entries() {
  local file="$1"
  local in_block=0 line seen=0
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    return 1
  fi
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [ "$in_block" = 1 ]; then
      if [[ "$line" == *'<!-- filer:end -->'* ]]; then
        break
      fi
      if [[ "$line" == '- id:'* ]]; then
        seen=1
      fi
    else
      if [[ "$line" == *'<!-- filer:begin -->'* ]]; then
        in_block=1
      fi
    fi
  done < "$file"
  [ "$seen" = 1 ]
}

# publish_draft PR MESSAGE — commit the session's pitch edit and post the reply,
# or refuse to commit when the session changed the owner's sprint block.
#
#   * PITCH_FILE differs from $PITCH_DIR/orig AND its pitch_sprint_block differs
#     from orig's: the session edited the owner's sprint block. Post a "Draft
#     not committed: the session changed the sprint block." comment and return
#     0 (no commit, no lint report). A failed POST is the same hold as below.
#   * PITCH_FILE differs (sprint block unchanged): commit it via pitch_pr_put
#     (contents API — the token's user, architect-bot, is the commit author). On
#     failure, log, set _OPUS_DISPATCH_FAILED, and return 1 so the next run
#     retries.
#   * Post one comment: the text of COMMENT_FILE (or "The session wrote
#     no reply."), a blank line, and the pitch-lint report. On POST failure,
#     stash that body (pending_reply_path), set _OPUS_DISPATCH_FAILED, and
#     return 1. The next cycle reposts it without a new session, including
#     when the pitch commit already landed.
publish_draft() {
  local pr="$1" message="$2"
  local orig="$PITCH_DIR/orig"
  local file_changed=0
  local block_file block_orig report reply comment_body
  # Stash a failed POST for the next cycle. The path matches pending_reply_path;
  # the fallback keeps an extracted publish_draft working when that helper is
  # not in scope (tests/acceptance/issue-1910.sh).
  _stash_failed_reply() {
    local stash_pr="$1" stash_body="$2" stash_path
    if declare -F pending_reply_path >/dev/null 2>&1; then
      stash_path="$(pending_reply_path "$stash_pr")"
    else
      stash_path="/tmp/architect-pending-reply-${PROJECT_NAME:-architect}-${stash_pr}"
    fi
    # First line is this cycle's NOW_ISO so a later repost does not mark
    # comments seen that arrived while the marker was held.
    if ! printf '%s\n%s' "${NOW_ISO:-}" "$stash_body" >"$stash_path"; then
      log "PR #${stash_pr}: could not stash the failed reply at ${stash_path}"
    fi
    log "PR #${stash_pr}: post_pr_comment failed — holding last-seen so the next run reposts"
    _OPUS_DISPATCH_FAILED=true
  }
  # content comparison, not path — the two files are always at different names.
  if ! diff -q "$PITCH_FILE" "$orig" >/dev/null 2>&1; then
    file_changed=1
  fi
  block_file="$(pitch_sprint_block "$PITCH_FILE" 2>/dev/null || true)"
  block_orig="$(pitch_sprint_block "$orig" 2>/dev/null || true)"
  if [ "$file_changed" = 1 ] && [ "$block_file" != "$block_orig" ]; then
    comment_body="Draft not committed: the session changed the sprint block."
    if ! post_pr_comment "$pr" "$comment_body"; then
      _stash_failed_reply "$pr" "$comment_body"
      return 1
    fi
    return 0
  fi
  if [ "$file_changed" = 1 ]; then
    if pitch_pr_put "$PITCH_BRANCH" "$PITCH_PATH" "$PITCH_SHA" "$PITCH_FILE" "$message"; then
      log "PR #${pr}: committed the drafted pitch to $PITCH_BRANCH"
    else
      log "PR #${pr}: pitch_pr_put failed — no commit; the next run retries"
      _OPUS_DISPATCH_FAILED=true
      return 1
    fi
  fi
  report="$("$FACTORY_ROOT/tools/pitch-lint.sh" "$PITCH_FILE" "$BACKLOG_FILE" || true)"
  reply="$(cat "$COMMENT_FILE" 2>/dev/null)"
  [ -n "$reply" ] || reply="The session wrote no reply."
  comment_body="$(printf '%s\n\n%s' "$reply" "$report")"
  if ! post_pr_comment "$pr" "$comment_body"; then
    _stash_failed_reply "$pr" "$comment_body"
    return 1
  fi
  return 0
}

# dispatch_decompose PR — the decompose state: a session drafts the sub-issues
# of a pitch that has its goal and sprint block but no entries. Mirrors
# _dispatch_opus_qa (formula, context, footer) but points the session at the
# three pitch paths and the Draft state. Bash commits the file and posts the
# reply via publish_draft.
dispatch_decompose() {
  local pr="$1"

  # Same hold as _dispatch_opus_qa: a load failure must not advance last-seen.
  if ! load_formula_or_profile "architect" "$ARCHITECT_FORMULA"; then
    log "PR #${pr}: formula load failed — holding last-seen"
    _OPUS_DISPATCH_FAILED=true
    return 1
  fi
  build_context_block VISION.md AGENTS.md ops:prerequisites.md
  formula_prepare_profile_context
  build_graph_section

  SCRATCH_CONTEXT=$(read_scratch_context "/tmp/architect-${PROJECT_NAME}-scratch.md")
  SCRATCH_INSTRUCTION=$(build_scratch_instruction "/tmp/architect-${PROJECT_NAME}-scratch.md")
  build_sdk_prompt_footer

  local prompt
  prompt=$(cat <<_PROMPT_EOF_
You are the architect agent for ${FORGE_REPO}. Work through the formula below.

${QA_ROLE_TEXT}

## CURRENT STATE: Draft the sub-issues

PITCH_FILE=${PITCH_FILE}
BACKLOG_FILE=${BACKLOG_FILE}
COMMENT_FILE=${COMMENT_FILE}

This is a fresh draft: the pitch carries its goal and its sprint block but has
no sub-issue entries. Draft the entries (docs/design/notes/issue-writing.md),
run tools/pitch-lint.sh "$PITCH_FILE" "$BACKLOG_FILE", and fix every ERROR.
Write the summary to COMMENT_FILE. Change only the entries between the filer
markers; the goal and the sprint block are the owner's.

## Project context
${CONTEXT_BLOCK}
${GRAPH_SECTION}
${SCRATCH_CONTEXT}
$(formula_lessons_block)
## Formula
${FORMULA_CONTENT}

${SCRATCH_INSTRUCTION}
${PROMPT_FOOTER}
_PROMPT_EOF_
  )

  agent_run --worktree "$WORKTREE" "$prompt" || {
    log "PR #${pr}: decompose dispatch FAILED (exit $?)"
    _OPUS_DISPATCH_FAILED=true
    return 1
  }
  log "opus decompose session complete"
  publish_draft "$pr" "architect: draft sub-issues"
}

# architect_pr_cycle — detect state, dispatch, and advance last-seen unless
# the dispatch failed. A stashed reply (failed comment POST) is reposted
# before any new session, so a pitch whose commit already landed still gets
# the reply and the marker stays put until that POST succeeds.
# Globals: PR_NUMBER, PR_BODY, LAST_SEEN, NOW_ISO, _OPUS_DISPATCH_FAILED.
architect_pr_cycle() {
  local pending_reply="" pending_seen="" reason="" updated=""
  local marker_iso="$NOW_ISO"
  _OPUS_DISPATCH_FAILED=false

  if has_reject_comment "$PR_NUMBER" "$LAST_SEEN"; then
    log "PR #${PR_NUMBER}: reject detected → closing"
    reason=$(get_reject_reason "$PR_NUMBER" "$LAST_SEEN")
    close_pr "$PR_NUMBER" "$reason"
  else
    pending_reply="$(read_pending_reply "$PR_NUMBER")"
    if [ -n "$pending_reply" ]; then
      pending_seen="$(read_pending_seen "$PR_NUMBER")"
      case "$pending_seen" in
        [0-9][0-9][0-9][0-9]-*) marker_iso="$pending_seen" ;;
      esac
      # Match the stashed body, not "any architect comment". A first-draft
      # reply must not drop a later revision whose POST failed.
      if pending_reply_already_posted "$PR_NUMBER" "$pending_reply"; then
        log "PR #${PR_NUMBER}: pending reply already on the thread — dropping the stash"
        clear_pending_reply "$PR_NUMBER"
      elif post_pr_comment "$PR_NUMBER" "$pending_reply"; then
        log "PR #${PR_NUMBER}: reposted the reply that failed last cycle"
        clear_pending_reply "$PR_NUMBER"
      else
        log "PR #${PR_NUMBER}: repost failed — holding last-seen"
        _OPUS_DISPATCH_FAILED=true
      fi
    elif prepare_pitch "$PR_NUMBER" && pitch_sprint_block "$PITCH_FILE" >/dev/null && ! pitch_has_entries "$PITCH_FILE" && ! architect_has_commented "$PR_NUMBER"; then
      log "PR #${PR_NUMBER}: decompose state — drafting sub-issues"
      dispatch_decompose "$PR_NUMBER" || true
    else
      log "PR #${PR_NUMBER}: q_and_a state"
      dispatch_q_and_a "$PR_NUMBER" "$PR_BODY" "$LAST_SEEN" || true
    fi
  fi

  # Update last-seen only if the dispatch succeeded. A failed dispatch must
  # be re-detected on the next cycle (others_comments_since drops comments
  # once the marker moves past them). A repost uses the failed cycle's
  # timestamp, so a comment that arrived during the retry stays unseen.
  if [ "$_OPUS_DISPATCH_FAILED" = false ]; then
    updated=$(update_last_seen "$PR_BODY" "$marker_iso")
    if [ -n "$updated" ] && [ "$updated" != "$PR_BODY" ]; then
      patch_pr_body "$PR_NUMBER" "$updated"
      log "Updated last-seen marker on PR #${PR_NUMBER}"
    fi
  else
    log "PR #${PR_NUMBER}: opus dispatch failed — skipping marker advance"
  fi
}

# ── Regression guard ───────────────────────────────────────────────────
check_architect_issue_filing() {
  local project_repo_path
  project_repo_path="/repos/${FORGE_REPO}/issues"

  if grep -q "POST.*${project_repo_path}" "$LOG_FILE" 2>/dev/null; then
    log "ERROR: regression detected — architect session attempted to POST to ${project_repo_path}"
    log "This violates the read-only contract established in #764."
    log "The architect-bot must NOT file issues directly on the project repo."
    log "Sub-issues are filed exclusively by filer-bot after sprint PR merge."
    echo "FATAL: architect-bot attempted direct issue creation on project repo" >&2
    exit 1
  fi
}

# ── Main: single linear flow ───────────────────────────────────────────

# Track whether any opus dispatch failed (prevents silent marker advancement)
_OPUS_DISPATCH_FAILED=false

# 1. List open architect PRs sorted by last-seen (round-robin)
pr_list=$(list_architect_prs_sorted)
if [ -z "$pr_list" ]; then
  log "No open architect PRs — exiting"
  check_architect_issue_filing
  exit 0
fi

# 2. Pick head of queue (first line = earliest last-seen)
head_pr_line=$(printf '%s\n' "$pr_list" | head -1)
PR_NUMBER="${head_pr_line%%|*}"
PR_UPDATED_AT="${head_pr_line##*|}"

log "Processing PR #${PR_NUMBER} (updated: ${PR_UPDATED_AT})"

# 3. Read PR state
PR_BODY=$(get_pr_body "$PR_NUMBER")
LAST_SEEN=$(extract_last_seen "$PR_BODY")

# If no last-seen marker exists, use PR updated_at as initial marker
if [ -z "$LAST_SEEN" ]; then
  LAST_SEEN="$PR_UPDATED_AT"
fi

NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# 4–5. Detect state, dispatch, and advance last-seen unless the dispatch failed.
#      architect_pr_cycle also reposts a stashed reply before any new session.
architect_pr_cycle

# ── Regression guard ───────────────────────────────────────────────────
check_architect_issue_filing

log "--- Architect run done ---"
