#!/usr/bin/env bash
# profile.sh — Agent .profile repository: lessons-learned digest + per-session journal
#
# Manages the agent .profile git repository: pre-session lessons loading,
# post-session journal writing, and lazy journal→digest→lessons-learned flow.
#
# Public:
#   profile_ensure_repo [AGENT_IDENTITY]            — clone/pull .profile repo
#   profile_prepare_context                         — load lessons from .profile repo (pre-session)
#   profile_lessons_block                           — return lessons block for prompt
#   profile_load_lessons                            — load lessons-learned.md into LESSONS_CONTEXT
#   profile_write_journal ISSUE TITLE OUTCOME [FILES] — post-session journal
#
# Private (underscore-prefixed, kept internal):
#   _profile_has_repo
#   _profile_count_undigested_journals               — count journal entries to digest
#   _profile_digest_journals                         — digest journals into lessons (timeout + batch cap)
#   _profile_restore_lessons                         — restore lessons on digest failure
#   _profile_commit_and_push                         — commit/push to .profile repo
#
# Requires: lib/env.sh, lib/agent-sdk.sh sourced first for shared helpers
#           (forge_whoami, claude_run_with_watchdog, log).

# ── .profile repo existence check ──────────────────────────────────────────

# _profile_has_repo
# Checks if the agent has a .profile repo by querying Forgejo API.
# Returns 0 if repo exists, 1 otherwise.
_profile_has_repo() {
  local agent_identity="${AGENT_IDENTITY:-}"

  if [ -z "$agent_identity" ]; then
    if ! resolve_agent_identity; then
      return 1
    fi
    agent_identity="$AGENT_IDENTITY"
  fi

  local forge_url="${FORGE_URL:-http://localhost:3000}"
  local api_url="${forge_url}/api/v1/repos/${agent_identity}/.profile"

  # Check if repo exists via API (returns 200 if exists, 404 if not)
  if curl -sf -o /dev/null -w "%{http_code}" \
      -H "Authorization: token ${FORGE_TOKEN}" \
      "$api_url" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ── .profile repo clone/pull ──────────────────────────────────────────────

# profile_ensure_repo [AGENT_IDENTITY]
# Clones or pulls the agent's .profile repo to a local cache dir.
# Requires: FORGE_TOKEN, FORGE_URL.
# Exports PROFILE_REPO_PATH (local cache path) and PROFILE_FORMULA_PATH.
# Returns 0 on success, 1 on failure (falls back gracefully).
# Note: $1 is optional (falls back to AGENT_IDENTITY global).
# shellcheck disable=SC2120
profile_ensure_repo() {
  local agent_identity="${1:-${AGENT_IDENTITY:-}}"

  if [ -z "$agent_identity" ]; then
    # Try to resolve from FORGE_TOKEN
    if ! resolve_agent_identity; then
      log "WARNING: cannot resolve agent identity, skipping .profile repo"
      return 1
    fi
    agent_identity="$AGENT_IDENTITY"
  fi

  # Define cache directory: /home/agent/data/.profile/{agent-name}
  PROFILE_REPO_PATH="${HOME:-/home/agent}/data/.profile/${agent_identity}"

  # Build clone URL from FORGE_URL — credential helper supplies auth (#604)
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  local clone_url="${forge_url}/${agent_identity}/.profile.git"

  # Check if already cached and up-to-date
  if [ -d "${PROFILE_REPO_PATH}/.git" ]; then
    log "Pulling .profile repo: ${agent_identity}/.profile"
    # Always refresh the remote URL to ensure it's clean (no baked credentials)
    # This fixes auth issues when old URLs contained the wrong username (#652)
    git -C "$PROFILE_REPO_PATH" remote set-url origin "$clone_url" 2>/dev/null || true
    if git -C "$PROFILE_REPO_PATH" fetch origin --quiet 2>/dev/null; then
      git -C "$PROFILE_REPO_PATH" checkout main --quiet 2>/dev/null || \
      git -C "$PROFILE_REPO_PATH" checkout master --quiet 2>/dev/null || true
      git -C "$PROFILE_REPO_PATH" pull --ff-only origin main --quiet 2>/dev/null || \
      git -C "$PROFILE_REPO_PATH" pull --ff-only origin master --quiet 2>/dev/null || true
      log ".profile repo pulled: ${PROFILE_REPO_PATH}"
    else
      log "WARNING: failed to pull .profile repo, using cached version"
    fi
  else
    log "Cloning .profile repo: ${agent_identity}/.profile -> ${PROFILE_REPO_PATH}"
    if git clone --quiet "$clone_url" "$PROFILE_REPO_PATH" 2>/dev/null; then
      log ".profile repo cloned: ${PROFILE_REPO_PATH}"
    else
      log "WARNING: failed to clone .profile repo ${agent_identity}/.profile — falling back to formulas/"
      return 1
    fi
  fi

  # Set formula path from .profile
  # shellcheck disable=SC2034  # exported to caller (load_formula_or_profile)
  PROFILE_FORMULA_PATH="${PROFILE_REPO_PATH}/formula.toml"
  return 0
}

# ── Journal counting ──────────────────────────────────────────────────────

# _profile_count_undigested_journals
# Counts journal entries in .profile/journal/ excluding archive/
# Returns count via stdout.
_profile_count_undigested_journals() {
  if [ ! -d "${PROFILE_REPO_PATH:-}/journal" ]; then
    echo "0"
    return
  fi
  find "${PROFILE_REPO_PATH}/journal" -maxdepth 1 -name "*.md" -type f ! -path "*/archive/*" 2>/dev/null | wc -l
}

# ── Journal digestion ─────────────────────────────────────────────────────

# _profile_digest_journals
# Runs a claude -p one-shot to digest undigested journals into lessons-learned.md
# Respects PROFILE_DIGEST_TIMEOUT (default 300s) and PROFILE_DIGEST_MAX_BATCH (default 5).
# On failure/timeout, preserves the previous lessons-learned.md and does not archive journals.
# Returns 0 on success, 1 on failure.
_profile_digest_journals() {
  local agent_identity="${AGENT_IDENTITY:-}"
  local model="${CLAUDE_MODEL:-opus}"
  local digest_timeout="${PROFILE_DIGEST_TIMEOUT:-300}"
  local max_batch="${PROFILE_DIGEST_MAX_BATCH:-5}"

  if [ -z "$agent_identity" ]; then
    if ! resolve_agent_identity; then
      return 1
    fi
    agent_identity="$AGENT_IDENTITY"
  fi

  local journal_dir="${PROFILE_REPO_PATH}/journal"
  local knowledge_dir="${PROFILE_REPO_PATH}/knowledge"
  local lessons_file="${knowledge_dir}/lessons-learned.md"

  # Collect undigested journal entries (capped at max_batch)
  local journal_entries=""
  local batch_count=0
  local -a batchfiles=()
  if [ -d "$journal_dir" ]; then
    for jf in "$journal_dir"/*.md; do
      [ -f "$jf" ] || continue
      # Skip archived entries
      [[ "$jf" == */archive/* ]] && continue
      if [ "$batch_count" -ge "$max_batch" ]; then
        log "profile: capping digest batch at ${max_batch} journals (remaining will be digested in future runs)"
        break
      fi
      local basename
      basename=$(basename "$jf")
      journal_entries="${journal_entries}
### ${basename}
$(cat "$jf")
"
      batchfiles+=("$jf")
      batch_count=$((batch_count + 1))
    done
  fi

  if [ -z "$journal_entries" ]; then
    log "profile: no undigested journals to digest"
    return 0
  fi

  log "profile: digesting ${batch_count} journals (timeout ${digest_timeout}s)"

  # Ensure knowledge directory exists
  mkdir -p "$knowledge_dir"

  # Back up existing lessons-learned.md so we can restore on failure
  local lessons_backup=""
  if [ -f "$lessons_file" ]; then
    lessons_backup=$(mktemp)
    cp "$lessons_file" "$lessons_backup"
  fi

  # Capture mtime so we can detect a Write-tool write afterwards
  local mtime_before=0
  [ -f "$lessons_file" ] && mtime_before=$(stat -c %Y "$lessons_file")

  # Build prompt for digestion
  local digest_prompt="You are digesting journal entries from a developer agent's work sessions.

## Task
Update the lessons-learned file at this exact absolute path:

  ${lessons_file}

1. Read ${lessons_file} (it may not exist yet — that's fine, treat as empty).
2. Digest the journal entries below into abstract, transferable patterns and heuristics.
3. Merge with the existing lessons: preserve anything still useful, refine, drop stale or redundant entries, add new ones.
4. Write the merged result back to ${lessons_file} using the Write tool.

## Constraints
- Hard cap: 2KB maximum
- Abstract: patterns and heuristics, not specific issues or file paths
- Transferable: must help with future unseen work, not just recall past work
- Drop the least transferable lessons if over the cap

## Journal entries to digest
${journal_entries}"

  # Run claude -p one-shot with digest-specific timeout
  local output digest_rc
  local saved_timeout="${CLAUDE_TIMEOUT:-7200}"
  CLAUDE_TIMEOUT="$digest_timeout"
  output=$(claude_run_with_watchdog claude -p "$digest_prompt" \
    --output-format json \
    --dangerously-skip-permissions \
    ${model:+--model "$model"} \
    2>>"$LOGFILE") && digest_rc=0 || digest_rc=$?
  CLAUDE_TIMEOUT="$saved_timeout"

  if [ "$digest_rc" -eq 124 ]; then
    log "profile: digest timed out after ${digest_timeout}s — preserving previous lessons, skipping archive"
    _profile_restore_lessons "$lessons_file" "$lessons_backup"
    return 1
  fi

  if [ "$digest_rc" -ne 0 ]; then
    log "profile: digest failed (exit code ${digest_rc}) — preserving previous lessons, skipping archive"
    _profile_restore_lessons "$lessons_file" "$lessons_backup"
    return 1
  fi

  local mtime_after=0
  [ -f "$lessons_file" ] && mtime_after=$(stat -c %Y "$lessons_file")

  if [ "$mtime_after" -gt "$mtime_before" ] && [ -s "$lessons_file" ]; then
    local file_size
    file_size=$(wc -c < "$lessons_file")
    # Treat tiny files (<=16 bytes) as failed digestion (e.g. "null", "{}", empty)
    if [ "$file_size" -le 16 ]; then
      log "profile: digest produced suspiciously small file (${file_size} bytes) — preserving previous lessons, skipping archive"
      _profile_restore_lessons "$lessons_file" "$lessons_backup"
      return 1
    fi
    log "profile: lessons-learned.md written by model via Write tool (${file_size} bytes)"
  else
    # Fallback: model didn't use Write tool — capture .result and strip any markdown code fence
    local lessons_content
    lessons_content=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null || echo "")
    lessons_content=$(printf '%s' "$lessons_content" | sed -E '1{/^```(markdown|md)?[[:space:]]*$/d;};${/^```[[:space:]]*$/d;}')

    if [ -z "$lessons_content" ] || [ "${#lessons_content}" -le 16 ]; then
      log "profile: failed to digest journals (no Write tool call, empty or tiny .result) — preserving previous lessons, skipping archive"
      _profile_restore_lessons "$lessons_file" "$lessons_backup"
      return 1
    fi

    printf '%s\n' "$lessons_content" > "$lessons_file"
    log "profile: lessons-learned.md written from .result fallback (${#lessons_content} bytes)"
  fi

  # Clean up backup on success
  [ -n "$lessons_backup" ] && rm -f "$lessons_backup"

  # Move only the digested journals to archive (not all — only the batch we processed)
  if [ ${#batchfiles[@]} -gt 0 ]; then
    mkdir -p "${journal_dir}/archive"
    local archived=0
    for jf in "${batchfiles[@]}"; do
      local basename
      basename=$(basename "$jf")
      mv "$jf" "${journal_dir}/archive/${basename}" 2>/dev/null && archived=$((archived + 1))
    done
    if [ "$archived" -gt 0 ]; then
      log "profile: archived ${archived} journal entries"
    fi
  fi

  # Commit and push the digest results
  _profile_commit_and_push \
    "profile: digest ${archived:-0} journals → knowledge/lessons-learned.md" \
    knowledge/lessons-learned.md \
    journal/

  return 0
}

# _profile_restore_lessons LESSONS_FILE BACKUP_FILE
# Restores previous lessons-learned.md from backup on digest failure.
_profile_restore_lessons() {
  local lessons_file="$1"
  local backup="$2"
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    cp "$backup" "$lessons_file"
    rm -f "$backup"
    log "profile: restored previous lessons-learned.md"
  fi
}

# _profile_commit_and_push MESSAGE [FILE ...]
# Commits and pushes changes to .profile repo.
_profile_commit_and_push() {
  local msg="$1"
  shift
  local files=("$@")

  if [ ! -d "${PROFILE_REPO_PATH:-}/.git" ]; then
    return 1
  fi

  (
    cd "$PROFILE_REPO_PATH" || return 1

    # Refresh the remote URL to ensure credentials are current (#652)
    # This ensures we use the correct bot identity and fresh credentials
    local forge_url="${FORGE_URL:-http://localhost:3000}"
    local agent_identity="${AGENT_IDENTITY:-}"
    if [ -n "$agent_identity" ]; then
      local remote_url="${forge_url}/${agent_identity}/.profile.git"
      git remote set-url origin "$remote_url" 2>/dev/null || true
    fi

    if [ ${#files[@]} -gt 0 ]; then
      git add "${files[@]}"
    else
      git add -A
    fi

    if ! git diff --cached --quiet 2>/dev/null; then
      git config user.name "${AGENT_IDENTITY}" || true
      git config user.email "${AGENT_IDENTITY}@disinto.local" || true
      git commit -m "$msg" --no-verify 2>/dev/null || true
      git push origin main --quiet 2>/dev/null || git push origin master --quiet 2>/dev/null || true
    fi
  )
}

# ── Lessons loading ───────────────────────────────────────────────────────

# profile_load_lessons
# Pre-session: loads lessons-learned.md into LESSONS_CONTEXT for prompt injection.
# Lazy digestion: if undigested journals exceed PROFILE_DIGEST_THRESHOLD (default 10),
# runs claude -p to digest them (bounded by PROFILE_DIGEST_MAX_BATCH and PROFILE_DIGEST_TIMEOUT).
# Returns 0 on success, 1 if agent has no .profile repo (silent no-op).
# Requires: profile_ensure_repo() called, AGENT_IDENTITY, FORGE_TOKEN, FORGE_URL, CLAUDE_MODEL.
# Exports: LESSONS_CONTEXT (the lessons file content, hard-capped at 2KB).
profile_load_lessons() {
  # Check if agent has .profile repo
  if ! _profile_has_repo; then
    return 0  # Silent no-op
  fi

  # Pull .profile repo
  if ! profile_ensure_repo; then
    return 0  # Silent no-op
  fi

  # Check journal count for lazy digestion trigger
  local journal_count digest_threshold
  journal_count=$(_profile_count_undigested_journals)
  digest_threshold="${PROFILE_DIGEST_THRESHOLD:-10}"

  if [ "${journal_count:-0}" -gt "$digest_threshold" ]; then
    log "profile: ${journal_count} undigested journals (threshold ${digest_threshold})"
    if ! _profile_digest_journals; then
      log "profile: warning — journal digestion failed, continuing with existing lessons"
    fi
  fi

  # Read lessons-learned.md (hard cap at 2KB)
  local lessons_file="${PROFILE_REPO_PATH}/knowledge/lessons-learned.md"
  LESSONS_CONTEXT=""

  if [ -f "$lessons_file" ]; then
    local lessons_content
    lessons_content=$(head -c 2048 "$lessons_file" 2>/dev/null) || lessons_content=""
    if [ -n "$lessons_content" ]; then
      # shellcheck disable=SC2034  # exported to caller for prompt injection
      # Raw content only — profile_lessons_block() adds the heading.
      LESSONS_CONTEXT="${lessons_content}"
      log "profile: loaded lessons-learned.md (${#lessons_content} bytes)"
    fi
  fi

  return 0
}

# profile_prepare_context
# Pre-session: loads lessons from .profile repo and sets LESSONS_CONTEXT for prompt injection.
# Single shared function to avoid duplicate boilerplate across agent scripts.
# Requires: AGENT_IDENTITY, FORGE_TOKEN, FORGE_URL (via profile_load_lessons).
# Exports: LESSONS_CONTEXT (set by profile_load_lessons).
# Returns 0 on success, 1 if agent has no .profile repo (silent no-op).
profile_prepare_context() {
  profile_load_lessons || true
  LESSONS_INJECTION="${LESSONS_CONTEXT:-}"
}

# profile_lessons_block
# Returns a formatted lessons block for prompt injection.
# Usage: LESSONS_BLOCK=$(profile_lessons_block)
# Expects: LESSONS_INJECTION to be set by profile_prepare_context.
# Returns: formatted block or empty string.
profile_lessons_block() {
  if [ -n "${LESSONS_INJECTION:-}" ]; then
    printf '\n## Lessons learned (from .profile/knowledge/lessons-learned.md)\n%s' "$LESSONS_INJECTION"
  fi
}

# ── Journal writing ───────────────────────────────────────────────────────

# profile_write_journal ISSUE_NUM ISSUE_TITLE OUTCOME [FILES_CHANGED]
# Post-session: writes a reflection journal entry after work completes.
# Returns 0 on success, 1 on failure.
# Requires: AGENT_IDENTITY, FORGE_TOKEN, FORGE_URL, CLAUDE_MODEL.
# Args:
#   $1 - ISSUE_NUM: The issue number worked on
#   $2 - ISSUE_TITLE: The issue title
#   $3 - OUTCOME: Session outcome (merged, blocked, failed, etc.)
#   $4 - FILES_CHANGED: Optional comma-separated list of files changed
profile_write_journal() {
  local issue_num="$1"
  local issue_title="$2"
  local outcome="$3"
  local files_changed="${4:-}"

  # Check if agent has .profile repo
  if ! _profile_has_repo; then
    return 0  # Silent no-op
  fi

  # Pull .profile repo
  if ! profile_ensure_repo; then
    return 0  # Silent no-op
  fi

  # Build session summary
  local session_summary=""
  if [ -n "$files_changed" ]; then
    session_summary="Files changed: ${files_changed}
"
  fi
  session_summary="${session_summary}Outcome: ${outcome}"

  # Build reflection prompt
  local reflection_prompt="You are reflecting on a development session. Write a concise journal entry about transferable lessons learned.

## Session context
- Issue: #${issue_num} — ${issue_title}
- Outcome: ${outcome}

${session_summary}

## Task
Write a journal entry focused on what you learned that would help you do similar work better next time.

## Constraints
- Be concise (100-200 words)
- Focus on transferable lessons, not a summary of what you did
- Abstract patterns and heuristics, not specific issue/file references
- One concise entry, not a list

## Output
Write the journal entry below. Use markdown format."

  # Run claude -p one-shot with same model as agent
  local output
  output=$(claude_run_with_watchdog claude -p "$reflection_prompt" \
    --output-format json \
    --dangerously-skip-permissions \
    ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} \
    2>>"$LOGFILE" || echo '{"result":"error"}')

  # Extract content from JSON response
  local journal_content
  journal_content=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null || echo "")

  if [ -z "$journal_content" ]; then
    log "profile: failed to write journal entry"
    return 1
  fi

  # Ensure journal directory exists
  local journal_dir="${PROFILE_REPO_PATH}/journal"
  mkdir -p "$journal_dir"

  # Write journal entry with timestamped filename for accumulation
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S)
  local journal_file="${journal_dir}/issue-${issue_num}-${ts}.md"
  printf '%s\n' "$journal_content" >> "$journal_file"
  log "profile: wrote journal entry for issue #${issue_num} (${ts})"

  # Commit and push to .profile repo
  _profile_commit_and_push "journal: issue #${issue_num} reflection (${ts})" "journal/issue-${issue_num}-${ts}.md"

  return 0
}
