#!/usr/bin/env bash
# formula-session.sh — Shared helpers for formula-driven cron agents
#
# Provides reusable utility functions for the common cron-wrapper pattern
# used by planner-run.sh, predictor-run.sh, gardener-run.sh, and supervisor-run.sh.
#
# Functions:
#   acquire_cron_lock   LOCK_FILE          — PID lock with stale cleanup
#   load_formula        FORMULA_FILE       — sets FORMULA_CONTENT
#   build_context_block FILE [FILE ...]    — sets CONTEXT_BLOCK
#   build_prompt_footer [EXTRA_API_LINES]  — sets PROMPT_FOOTER (API ref + env)
#   build_sdk_prompt_footer [EXTRA_API]    — omits phase protocol (SDK mode)
#   formula_worktree_setup WORKTREE        — isolated worktree for formula execution
#   formula_prepare_profile_context        — load lessons from .profile repo (pre-session)
#   formula_lessons_block                  — return lessons block for prompt
#   profile_write_journal ISSUE_NUM TITLE OUTCOME [FILES] — post-session journal
#   profile_load_lessons                   — load lessons-learned.md into LESSONS_CONTEXT
#   ensure_profile_repo [AGENT_IDENTITY]   — clone/pull .profile repo
#   _profile_has_repo                      — check if agent has .profile repo
#   _count_undigested_journals             — count journal entries to digest
#   _profile_digest_journals               — digest journals into lessons
#   _profile_commit_and_push MESSAGE [FILES] — commit/push to .profile repo
#   resolve_agent_identity                 — resolve agent user login from FORGE_TOKEN
#   build_graph_section                    — run build-graph.py and set GRAPH_SECTION
#   build_scratch_instruction SCRATCH_FILE — return context scratch instruction
#   read_scratch_context SCRATCH_FILE      — return scratch file content block
#   ensure_ops_repo                        — clone/pull ops repo
#   ops_commit_and_push MESSAGE [FILES]    — commit/push to ops repo
#   cleanup_stale_crashed_worktrees [HOURS] — thin wrapper around worktree_cleanup_stale
#
# Requires: lib/env.sh, lib/worktree.sh sourced first for shared helpers.

# ── Cron guards ──────────────────────────────────────────────────────────

# acquire_cron_lock LOCK_FILE
# Acquires a PID lock. Exits 0 if another instance is running.
# Sets an EXIT trap to clean up the lock file.
acquire_cron_lock() {
  _CRON_LOCK_FILE="$1"
  if [ -f "$_CRON_LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$_CRON_LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "run: already running (PID $lock_pid)"
      exit 0
    fi
    rm -f "$_CRON_LOCK_FILE"
  fi
  echo $$ > "$_CRON_LOCK_FILE"
  trap 'rm -f "$_CRON_LOCK_FILE"' EXIT
}

# ── Agent identity resolution ────────────────────────────────────────────

# resolve_agent_identity
# Resolves the agent identity (user login) from the FORGE_TOKEN.
# Exports AGENT_IDENTITY (user login string).
# Returns 0 on success, 1 on failure.
resolve_agent_identity() {
  if [ -z "${FORGE_TOKEN:-}" ]; then
    log "WARNING: FORGE_TOKEN not set, cannot resolve agent identity"
    return 1
  fi
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  AGENT_IDENTITY=$(curl -sf --max-time 10 \
    -H "Authorization: token ${FORGE_TOKEN}" \
    "${forge_url}/api/v1/user" 2>/dev/null | jq -r '.login // empty' 2>/dev/null) || true
  if [ -z "$AGENT_IDENTITY" ]; then
    log "WARNING: failed to resolve agent identity from FORGE_TOKEN"
    return 1
  fi
  log "Resolved agent identity: ${AGENT_IDENTITY}"
  return 0
}

# ── Forge remote resolution ──────────────────────────────────────────────

# resolve_forge_remote
# Resolves FORGE_REMOTE by matching FORGE_URL hostname against git remotes.
# Falls back to "origin" if no match found.
# Requires: FORGE_URL, git repo with remotes configured.
# Exports: FORGE_REMOTE (always set).
resolve_forge_remote() {
  # Extract hostname from FORGE_URL (e.g., https://codeberg.org/user/repo -> codeberg.org)
  _forge_host=$(printf '%s' "$FORGE_URL" | sed 's|https\?://||; s|/.*||; s|:.*||')
  # Find git remote whose push URL matches the forge host
  FORGE_REMOTE=$(git remote -v | awk -v host="$_forge_host" '$2 ~ host && /\(push\)/ {print $1; exit}')
  # Fallback to origin if no match found
  FORGE_REMOTE="${FORGE_REMOTE:-origin}"
  export FORGE_REMOTE
  log "forge remote: ${FORGE_REMOTE}"
}

# ── .profile repo management ──────────────────────────────────────────────

# ensure_profile_repo [AGENT_IDENTITY]
# Clones or pulls the agent's .profile repo to a local cache dir.
# Requires: FORGE_TOKEN, FORGE_URL.
# Exports PROFILE_REPO_PATH (local cache path) and PROFILE_FORMULA_PATH.
# Returns 0 on success, 1 on failure (falls back gracefully).
ensure_profile_repo() {
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

  # Build clone URL from FORGE_URL and agent identity
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  local auth_url
  auth_url=$(printf '%s' "$forge_url" | sed "s|://|://$(whoami):${FORGE_TOKEN}@|")
  local clone_url="${auth_url}/${agent_identity}/.profile.git"

  # Check if already cached and up-to-date
  if [ -d "${PROFILE_REPO_PATH}/.git" ]; then
    log "Pulling .profile repo: ${agent_identity}/.profile"
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
  PROFILE_FORMULA_PATH="${PROFILE_REPO_PATH}/formula.toml"
  return 0
}

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

# _count_undigested_journals
# Counts journal entries in .profile/journal/ excluding archive/
# Returns count via stdout.
_count_undigested_journals() {
  if [ ! -d "${PROFILE_REPO_PATH:-}/journal" ]; then
    echo "0"
    return
  fi
  find "${PROFILE_REPO_PATH}/journal" -maxdepth 1 -name "*.md" -type f ! -path "*/archive/*" 2>/dev/null | wc -l
}

# _profile_digest_journals
# Runs a claude -p one-shot to digest undigested journals into lessons-learned.md
# Returns 0 on success, 1 on failure.
_profile_digest_journals() {
  local agent_identity="${AGENT_IDENTITY:-}"
  local model="${CLAUDE_MODEL:-opus}"

  if [ -z "$agent_identity" ]; then
    if ! resolve_agent_identity; then
      return 1
    fi
    agent_identity="$AGENT_IDENTITY"
  fi

  local journal_dir="${PROFILE_REPO_PATH}/journal"
  local knowledge_dir="${PROFILE_REPO_PATH}/knowledge"
  local lessons_file="${knowledge_dir}/lessons-learned.md"

  # Collect undigested journal entries
  local journal_entries=""
  if [ -d "$journal_dir" ]; then
    for jf in "$journal_dir"/*.md; do
      [ -f "$jf" ] || continue
      # Skip archived entries
      [[ "$jf" == */archive/* ]] && continue
      local basename
      basename=$(basename "$jf")
      journal_entries="${journal_entries}
### ${basename}
$(cat "$jf")
"
    done
  fi

  if [ -z "$journal_entries" ]; then
    log "profile: no undigested journals to digest"
    return 0
  fi

  # Read existing lessons if available
  local existing_lessons=""
  if [ -f "$lessons_file" ]; then
    existing_lessons=$(cat "$lessons_file")
  fi

  # Build prompt for digestion
  local digest_prompt="You are digesting journal entries from a developer agent's work sessions.

## Task
Condense these journal entries into abstract, transferable lessons. Rewrite lessons-learned.md entirely.

## Constraints
- Hard cap: 2KB maximum
- Abstract: patterns and heuristics, not specific issues or file paths
- Transferable: must help with future unseen work, not just recall past work
- Drop the least transferable lessons if over limit

## Existing lessons-learned.md (if any)
${existing_lessons:-<none>}

## Journal entries to digest
${journal_entries}

## Output
Write the complete, rewritten lessons-learned.md content below. No preamble, no explanation — just the file content."

  # Run claude -p one-shot with same model as agent
  local output
  output=$(claude -p "$digest_prompt" \
    --output-format json \
    --dangerously-skip-permissions \
    --max-tokens 1000 \
    ${model:+--model "$model"} \
    2>>"$LOGFILE" || echo '{"result":"error"}')

  # Extract content from JSON response
  local lessons_content
  lessons_content=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null || echo "")

  if [ -z "$lessons_content" ]; then
    log "profile: failed to digest journals"
    return 1
  fi

  # Ensure knowledge directory exists
  mkdir -p "$knowledge_dir"

  # Write the lessons file (full rewrite)
  printf '%s\n' "$lessons_content" > "$lessons_file"
  log "profile: wrote lessons-learned.md (${#lessons_content} bytes)"

  # Move digested journals to archive (if any were processed)
  if [ -d "$journal_dir" ]; then
    mkdir -p "${journal_dir}/archive"
    local archived=0
    for jf in "$journal_dir"/*.md; do
      [ -f "$jf" ] || continue
      [[ "$jf" == */archive/* ]] && continue
      local basename
      basename=$(basename "$jf")
      mv "$jf" "${journal_dir}/archive/${basename}" 2>/dev/null && archived=$((archived + 1))
    done
    if [ "$archived" -gt 0 ]; then
      log "profile: archived ${archived} journal entries"
    fi
  fi

  return 0
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

    if [ ${#files[@]} -gt 0 ]; then
      git add "${files[@]}"
    else
      git add -A
    fi

    if ! git diff --cached --quiet 2>/dev/null; then
      git config user.name "${AGENT_IDENTITY}" || true
      git config user.email "${AGENT_IDENTITY}@users.noreply.codeberg.org" || true
      git commit -m "$msg" --no-verify 2>/dev/null || true
      git push origin main --quiet 2>/dev/null || git push origin master --quiet 2>/dev/null || true
    fi
  )
}

# profile_load_lessons
# Pre-session: loads lessons-learned.md into LESSONS_CONTEXT for prompt injection.
# Lazy digestion: if >10 undigested journals exist, runs claude -p to digest them.
# Returns 0 on success, 1 if agent has no .profile repo (silent no-op).
# Requires: ensure_profile_repo() called, AGENT_IDENTITY, FORGE_TOKEN, FORGE_URL, CLAUDE_MODEL.
# Exports: LESSONS_CONTEXT (the lessons file content, hard-capped at 2KB).
profile_load_lessons() {
  # Check if agent has .profile repo
  if ! _profile_has_repo; then
    return 0  # Silent no-op
  fi

  # Pull .profile repo
  if ! ensure_profile_repo; then
    return 0  # Silent no-op
  fi

  # Check journal count for lazy digestion trigger
  local journal_count
  journal_count=$(_count_undigested_journals)

  if [ "${journal_count:-0}" -gt 10 ]; then
    log "profile: digesting ${journal_count} undigested journals"
    if ! _profile_digest_journals; then
      log "profile: warning — journal digestion failed"
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
      LESSONS_CONTEXT="## Lessons learned (from .profile/knowledge/lessons-learned.md)
${lessons_content}"
      log "profile: loaded lessons-learned.md (${#lessons_content} bytes)"
    fi
  fi

  return 0
}

# formula_prepare_profile_context
# Pre-session: loads lessons from .profile repo and sets LESSONS_CONTEXT for prompt injection.
# Single shared function to avoid duplicate boilerplate across agent scripts.
# Requires: AGENT_IDENTITY, FORGE_TOKEN, FORGE_URL (via profile_load_lessons).
# Exports: LESSONS_CONTEXT (set by profile_load_lessons).
# Returns 0 on success, 1 if agent has no .profile repo (silent no-op).
formula_prepare_profile_context() {
  profile_load_lessons || true
  LESSONS_INJECTION="${LESSONS_CONTEXT:-}"
}

# formula_lessons_block
# Returns a formatted lessons block for prompt injection.
# Usage: LESSONS_BLOCK=$(formula_lessons_block)
# Expects: LESSONS_INJECTION to be set by formula_prepare_profile_context.
# Returns: formatted block or empty string.
formula_lessons_block() {
  if [ -n "${LESSONS_INJECTION:-}" ]; then
    printf '\n## Lessons learned (from .profile/knowledge/lessons-learned.md)\n%s' "$LESSONS_INJECTION"
  fi
}

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
  if ! ensure_profile_repo; then
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
  output=$(claude -p "$reflection_prompt" \
    --output-format json \
    --dangerously-skip-permissions \
    --max-tokens 500 \
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

  # Write journal entry (append if exists)
  local journal_file="${journal_dir}/issue-${issue_num}.md"
  if [ -f "$journal_file" ]; then
    printf '\n---\n\n' >> "$journal_file"
  fi
  printf '%s\n' "$journal_content" >> "$journal_file"
  log "profile: wrote journal entry for issue #${issue_num}"

  # Commit and push to .profile repo
  _profile_commit_and_push "journal: issue #${issue_num} reflection" "journal/issue-${issue_num}.md"

  return 0
}

# ── Formula loading ──────────────────────────────────────────────────────

# load_formula FORMULA_FILE
# Reads formula TOML into FORMULA_CONTENT. Exits 1 if missing.
load_formula() {
  local formula_file="$1"
  if [ ! -f "$formula_file" ]; then
    log "ERROR: formula not found: $formula_file"
    exit 1
  fi
  # shellcheck disable=SC2034  # consumed by the calling script
  FORMULA_CONTENT=$(cat "$formula_file")
}

# load_formula_or_profile [ROLE] [FORMULA_FILE]
# Tries to load formula from .profile repo first, falls back to formulas/<role>.toml.
# Requires: AGENT_IDENTITY, ensure_profile_repo() available.
# Exports: FORMULA_CONTENT, FORMULA_SOURCE (either ".profile" or "formulas/").
# Returns 0 on success, 1 on failure.
load_formula_or_profile() {
  local role="${1:-}"
  local fallback_formula="${2:-}"

  # Try to load from .profile repo
  if [ -n "$AGENT_IDENTITY" ] && ensure_profile_repo "$AGENT_IDENTITY"; then
    if [ -f "$PROFILE_FORMULA_PATH" ]; then
      log "formula source: .profile (${PROFILE_FORMULA_PATH})"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$PROFILE_FORMULA_PATH")"
      FORMULA_SOURCE=".profile"
      return 0
    else
      log "WARNING: .profile repo exists but formula.toml not found at ${PROFILE_FORMULA_PATH}"
    fi
  fi

  # Fallback to formulas/<role>.toml
  if [ -n "$fallback_formula" ]; then
    if [ -f "$fallback_formula" ]; then
      log "formula source: formulas/ (fallback) — ${fallback_formula}"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$fallback_formula")"
      FORMULA_SOURCE="formulas/"
      return 0
    else
      log "ERROR: formula not found in .profile and fallback file not found: $fallback_formula"
      return 1
    fi
  fi

  # No fallback specified but role provided — construct fallback path
  if [ -n "$role" ]; then
    fallback_formula="${FACTORY_ROOT}/formulas/${role}.toml"
    if [ -f "$fallback_formula" ]; then
      log "formula source: formulas/ (fallback) — ${fallback_formula}"
      # shellcheck disable=SC2034
      FORMULA_CONTENT="$(cat "$fallback_formula")"
      # shellcheck disable=SC2034
      FORMULA_SOURCE="formulas/"
      return 0
    fi
  fi

  # No fallback specified
  log "ERROR: formula not found in .profile and no fallback specified"
  return 1
}

# build_context_block FILE [FILE ...]
# Reads each file from $PROJECT_REPO_ROOT and builds CONTEXT_BLOCK.
# Files prefixed with "ops:" are read from $OPS_REPO_ROOT instead.
build_context_block() {
  CONTEXT_BLOCK=""
  local ctx ctx_path ctx_label
  for ctx in "$@"; do
    case "$ctx" in
      ops:*)
        ctx_label="${ctx#ops:}"
        ctx_path="${OPS_REPO_ROOT}/${ctx_label}"
        ;;
      *)
        ctx_label="$ctx"
        ctx_path="${PROJECT_REPO_ROOT}/${ctx}"
        ;;
    esac
    if [ -f "$ctx_path" ]; then
      CONTEXT_BLOCK="${CONTEXT_BLOCK}
### ${ctx_label}
$(cat "$ctx_path")
"
    fi
  done
}

# ── Ops repo helpers ────────────────────────────────────────────────────

# ensure_ops_repo
# Clones or pulls the ops repo so agents can read/write operational data.
# Requires: OPS_REPO_ROOT, FORGE_OPS_REPO, FORGE_URL, FORGE_TOKEN.
# No-op if OPS_REPO_ROOT already exists and is up-to-date.
ensure_ops_repo() {
  local ops_root="${OPS_REPO_ROOT:-}"
  [ -n "$ops_root" ] || return 0

  if [ -d "${ops_root}/.git" ]; then
    # Pull latest from primary branch
    git -C "$ops_root" fetch origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    git -C "$ops_root" checkout "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    git -C "$ops_root" pull --ff-only origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    return 0
  fi

  # Clone from Forgejo
  local ops_repo="${FORGE_OPS_REPO:-}"
  [ -n "$ops_repo" ] || return 0
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  local clone_url
  if [ -n "${FORGE_TOKEN:-}" ]; then
    local auth_url
    auth_url=$(printf '%s' "$forge_url" | sed "s|://|://$(whoami):${FORGE_TOKEN}@|")
    clone_url="${auth_url}/${ops_repo}.git"
  else
    clone_url="${forge_url}/${ops_repo}.git"
  fi

  log "Cloning ops repo: ${ops_repo} -> ${ops_root}"
  if git clone --quiet "$clone_url" "$ops_root" 2>/dev/null; then
    log "Ops repo cloned: ${ops_root}"
  else
    log "WARNING: failed to clone ops repo ${ops_repo} — creating local directory"
    mkdir -p "$ops_root"
  fi
}

# ops_commit_and_push MESSAGE [FILE ...]
# Stage, commit, and push changes in the ops repo.
# If no files specified, stages all changes.
ops_commit_and_push() {
  local msg="$1"
  shift
  local ops_root="${OPS_REPO_ROOT:-}"
  [ -d "${ops_root}/.git" ] || return 0

  (
    cd "$ops_root" || return
    if [ $# -gt 0 ]; then
      git add "$@"
    else
      git add -A
    fi
    if ! git diff --cached --quiet; then
      git commit -m "$msg"
      git push origin "${PRIMARY_BRANCH}" --quiet 2>/dev/null || true
    fi
  )
}

# ── Scratch file helpers (compaction survival) ────────────────────────────

# build_scratch_instruction SCRATCH_FILE
# Returns a prompt block instructing Claude to periodically flush context
# to a scratch file so understanding survives context compaction.
build_scratch_instruction() {
  local scratch_file="$1"
  cat <<_SCRATCH_EOF_
## Context scratch file (compaction survival)

Periodically (every 10-15 tool calls), write a summary of:
- What you have discovered so far
- Decisions made and why
- What remains to do
to: ${scratch_file}

If this file existed at session start, its contents have already been injected into your prompt above.
This file is ephemeral — not evidence or permanent memory, just a compaction survival mechanism.
_SCRATCH_EOF_
}

# read_scratch_context SCRATCH_FILE
# If the scratch file exists, returns a context block for prompt injection.
# Returns empty string if the file does not exist.
read_scratch_context() {
  local scratch_file="$1"
  if [ -f "$scratch_file" ]; then
    printf '## Previous context (from scratch file)\n%s\n' "$(head -c 8192 "$scratch_file")"
  fi
}

# ── Graph report helper ───────────────────────────────────────────────────

# build_graph_section
# Runs build-graph.py and sets GRAPH_SECTION to a markdown block containing
# the JSON report.  Sets GRAPH_SECTION="" on failure (non-fatal).
# Requires globals: PROJECT_NAME, FACTORY_ROOT, PROJECT_REPO_ROOT, LOG_FILE.
build_graph_section() {
  local report="/tmp/${PROJECT_NAME}-graph-report.json"
  # shellcheck disable=SC2034  # consumed by the calling script's PROMPT
  GRAPH_SECTION=""
  if python3 "$FACTORY_ROOT/lib/build-graph.py" \
       --project-root "$PROJECT_REPO_ROOT" \
       --output "$report" 2>>"$LOG_FILE"; then
    # shellcheck disable=SC2034
    local report_content
    report_content="$(cat "$report")"
    # shellcheck disable=SC2034
    GRAPH_SECTION="
## Structural analysis
\`\`\`json
${report_content}
\`\`\`"
    log "graph report generated: $(jq -r '.stats | "\(.nodes) nodes, \(.edges) edges"' "$report")"
  else
    log "WARN: build-graph.py failed — continuing without structural analysis"
  fi
}

# ── SDK helpers ───────────────────────────────────────────────────────────

# build_sdk_prompt_footer [EXTRA_API_LINES]
# Like build_prompt_footer but omits the phase protocol section (SDK mode).
# Sets PROMPT_FOOTER.
build_sdk_prompt_footer() {
  # shellcheck disable=SC2034  # consumed by build_prompt_footer
  PHASE_FILE=""  # not used in SDK mode
  build_prompt_footer "${1:-}"
  PROMPT_FOOTER="${PROMPT_FOOTER%%## Phase protocol*}"
}

# formula_worktree_setup WORKTREE
# Creates an isolated worktree for synchronous formula execution.
# Fetches primary branch, cleans stale worktree, creates new one, and
# sets an EXIT trap for cleanup.
# Requires globals: PROJECT_REPO_ROOT, PRIMARY_BRANCH, FORGE_REMOTE.
# Ensure resolve_forge_remote() is called before this function.
formula_worktree_setup() {
  local worktree="$1"
  cd "$PROJECT_REPO_ROOT" || return
  git fetch "${FORGE_REMOTE}" "$PRIMARY_BRANCH" 2>/dev/null || true
  worktree_cleanup "$worktree"
  git worktree add "$worktree" "${FORGE_REMOTE}/${PRIMARY_BRANCH}" --detach 2>/dev/null
  # shellcheck disable=SC2064  # expand worktree now, not at trap time
  trap "worktree_cleanup '$worktree'" EXIT
}

# ── Prompt helpers ──────────────────────────────────────────────────────

# build_prompt_footer [EXTRA_API_LINES]
# Assembles the common forge API reference + environment block for formula prompts.
# Sets PROMPT_FOOTER.
# Pass additional API endpoint lines (pre-formatted, newline-prefixed) via $1.
# Requires globals: FORGE_API, FACTORY_ROOT, PROJECT_REPO_ROOT,
#                   PRIMARY_BRANCH.
build_prompt_footer() {
  local extra_api="${1:-}"
  # shellcheck disable=SC2034  # consumed by the calling script's PROMPT
  PROMPT_FOOTER="## Forge API reference
Base URL: ${FORGE_API}
Auth header: -H \"Authorization: token \${FORGE_TOKEN}\"
  Read issue:  curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/issues/{number}' | jq '.body'
  Create issue: curl -sf -X POST -H \"Authorization: token \${FORGE_TOKEN}\" -H 'Content-Type: application/json' '${FORGE_API}/issues' -d '{\"title\":\"...\",\"body\":\"...\",\"labels\":[LABEL_ID]}'${extra_api}
  List labels: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/labels'
NEVER echo or include the actual token value in output — always reference \${FORGE_TOKEN}.

## Environment
FACTORY_ROOT=${FACTORY_ROOT}
PROJECT_REPO_ROOT=${PROJECT_REPO_ROOT}
OPS_REPO_ROOT=${OPS_REPO_ROOT}
PRIMARY_BRANCH=${PRIMARY_BRANCH}"
}

# ── Stale crashed worktree cleanup ────────────────────────────────────────

# cleanup_stale_crashed_worktrees [MAX_AGE_HOURS]
# Thin wrapper around worktree_cleanup_stale() from lib/worktree.sh.
# Kept for backwards compatibility with existing callers.
# Requires: lib/worktree.sh sourced.
cleanup_stale_crashed_worktrees() {
  worktree_cleanup_stale "${1:-24}"
}
