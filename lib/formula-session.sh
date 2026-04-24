#!/usr/bin/env bash
# formula-session.sh — Shared helpers for formula-driven polling-loop agents
#
# Provides reusable utility functions for the common polling-loop wrapper pattern
# used by planner-run.sh, predictor-run.sh, gardener-run.sh, and supervisor-run.sh.
#
# Functions:
#   acquire_run_lock    LOCK_FILE          — PID lock with stale cleanup
#   load_formula        FORMULA_FILE       — sets FORMULA_CONTENT
#   build_context_block FILE [FILE ...]    — sets CONTEXT_BLOCK
#   build_prompt_footer [EXTRA_API_LINES]  — sets PROMPT_FOOTER (API ref + env)
#   build_sdk_prompt_footer [EXTRA_API]    — omits phase protocol (SDK mode)
#   formula_worktree_setup WORKTREE        — isolated worktree for formula execution
#   resolve_agent_identity                 — resolve agent user login from FORGE_TOKEN
#   build_graph_section                    — run build-graph.py and set GRAPH_SECTION
#   build_scratch_instruction SCRATCH_FILE — return context scratch instruction
#   read_scratch_context SCRATCH_FILE      — return scratch file content block
#   ensure_ops_repo                        — clone/pull ops repo
#   ops_commit_and_push MESSAGE [FILES]    — commit/push to ops repo
#   cleanup_stale_crashed_worktrees [HOURS] — thin wrapper around worktree_cleanup_stale
#   load_formula_or_profile [ROLE] [FORMULA_FILE] — load from .profile or fallback
#
# Subsystems (sourced):
#   profile.sh  — agent .profile repository: lessons-learned digest + per-session journal
#
# Requires: lib/env.sh, lib/worktree.sh, lib/agent-sdk.sh sourced first for shared helpers.

# Source agent-sdk for claude_run_with_watchdog watchdog helper
source "$(dirname "${BASH_SOURCE[0]}")/agent-sdk.sh"

# Source ops-setup for migrate_ops_repo (used by ensure_ops_repo)
source "$(dirname "${BASH_SOURCE[0]}")/ops-setup.sh"

# Source profile for .profile repo / lessons-learned digest subsystem
source "$(dirname "${BASH_SOURCE[0]}")/profile.sh"

# ── Run guards ───────────────────────────────────────────────────────────

# acquire_run_lock LOCK_FILE
# Acquires a PID lock. Exits 0 if another instance is running.
# Sets an EXIT trap to clean up the lock file.
acquire_run_lock() {
  _RUN_LOCK_FILE="$1"
  if [ -f "$_RUN_LOCK_FILE" ]; then
    local lock_pid
    lock_pid=$(cat "$_RUN_LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      log "run: already running (PID $lock_pid)"
      exit 0
    fi
    rm -f "$_RUN_LOCK_FILE"
  fi
  echo $$ > "$_RUN_LOCK_FILE"
  trap 'rm -f "$_RUN_LOCK_FILE"' EXIT
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
  AGENT_IDENTITY=$(forge_whoami)
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
# Requires: AGENT_IDENTITY, profile_ensure_repo() available.
# Exports: FORMULA_CONTENT, FORMULA_SOURCE (either ".profile" or "formulas/").
# Returns 0 on success, 1 on failure.
load_formula_or_profile() {
  local role="${1:-}"
  local fallback_formula="${2:-}"

  # Try to load from .profile repo
  if [ -n "$AGENT_IDENTITY" ] && profile_ensure_repo "$AGENT_IDENTITY"; then
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
    migrate_ops_repo "$ops_root" "${PRIMARY_BRANCH}"
    return 0
  fi

  # Clone from Forgejo
  local ops_repo="${FORGE_OPS_REPO:-}"
  [ -n "$ops_repo" ] || return 0
  local forge_url="${FORGE_URL:-http://localhost:3000}"
  # Use clean URL — credential helper supplies auth (#604)
  local clone_url="${forge_url}/${ops_repo}.git"

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
# Requires globals: PROJECT_REPO_ROOT, PRIMARY_BRANCH.
# Self-heals FORGE_REMOTE by calling resolve_forge_remote when unset — this
# eliminates a silent-abort bug class in callers that forgot the precondition
# (see #1120 / #551). Callers still need FORGE_URL set so resolve_forge_remote
# can match a git remote (or fall back to "origin").
formula_worktree_setup() {
  local worktree="$1"
  cd "$PROJECT_REPO_ROOT" || return
  if [ -z "${FORGE_REMOTE:-}" ]; then
    resolve_forge_remote
  fi
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
  List labels: curl -sf -H \"Authorization: token \${FORGE_TOKEN}\" '${FORGE_API}/labels'${extra_api}
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

# ── Back-compat shims (deprecated — update callers to use profile_*) ────
# These shims exist so existing callers aren't broken on day one.
# Remove after follow-up PRs update callers to the new names.

# Deprecated: use profile_prepare_context instead
formula_prepare_profile_context() { profile_prepare_context "$@"; }

# Deprecated: use profile_lessons_block instead
formula_lessons_block() { profile_lessons_block "$@"; }

# Deprecated: use profile_ensure_repo instead
ensure_profile_repo() { profile_ensure_repo "$@"; }
