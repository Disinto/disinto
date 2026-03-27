#!/usr/bin/env bash
# worktree.sh — Reusable git worktree management for agents
#
# Functions:
#   worktree_create   PATH BRANCH [BASE_REF]  — create worktree, checkout base, fetch submodules
#   worktree_recover  ISSUE_NUMBER PROJECT_NAME — detect existing PR/branch, reuse or recreate worktree
#   worktree_cleanup  PATH                     — remove worktree + Claude Code project cache
#   worktree_cleanup_stale [MAX_AGE_HOURS]     — prune orphaned /tmp worktrees older than threshold
#   worktree_preserve PATH REASON              — mark worktree as preserved (skip cleanup on exit)
#
# Requires: lib/env.sh sourced (for FACTORY_ROOT, PROJECT_REPO_ROOT, log()).
# Globals set by callers: FORGE_REMOTE (git remote name, default "origin").

# --- Internal: clear Claude Code project cache for a worktree path ---
_worktree_clear_claude_cache() {
  local wt_path="$1"
  local claude_project_dir
  claude_project_dir="$HOME/.claude/projects/$(echo "$wt_path" | sed 's|/|-|g; s|^-||')"
  rm -rf "$claude_project_dir" 2>/dev/null || true
}

# worktree_create PATH BRANCH [BASE_REF]
# Creates a git worktree at PATH on BRANCH, based on BASE_REF (default: FORGE_REMOTE/PRIMARY_BRANCH).
# Fetches submodules after creation. Cleans up any stale worktree at PATH first.
# Must be called from PROJECT_REPO_ROOT (or a repo directory).
# Returns 0 on success, 1 on failure.
worktree_create() {
  local wt_path="$1"
  local branch="$2"
  local base_ref="${3:-${FORGE_REMOTE:-origin}/${PRIMARY_BRANCH:-main}}"

  # Clean up any prior worktree at this path
  worktree_cleanup "$wt_path"

  if ! git worktree add "$wt_path" "$base_ref" -B "$branch" 2>&1; then
    return 1
  fi

  cd "$wt_path" || return 1
  git checkout -B "$branch" "$base_ref" 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
  return 0
}

# worktree_recover WORKTREE_PATH BRANCH FORGE_REMOTE
# Detects an existing worktree at WORKTREE_PATH. If it exists and is on the
# right BRANCH, reuses it (fast-forward pull). Otherwise, cleans and recreates.
# Sets _WORKTREE_REUSED=true if the existing worktree was reused.
# Must be called from PROJECT_REPO_ROOT (or a repo directory).
# Returns 0 on success, 1 on failure.
worktree_recover() {
  local wt_path="$1"
  local branch="$2"
  local remote="${3:-${FORGE_REMOTE:-origin}}"

  _WORKTREE_REUSED=false

  git fetch "$remote" "$branch" 2>/dev/null || true

  # Reuse existing worktree if on the right branch
  if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
    local wt_branch
    wt_branch=$(cd "$wt_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    if [ "$wt_branch" = "$branch" ]; then
      cd "$wt_path" || return 1
      git pull --ff-only "$remote" "$branch" 2>/dev/null || git reset --hard "${remote}/${branch}" 2>/dev/null || true
      _WORKTREE_REUSED=true
      return 0
    fi
  fi

  # Clean and recreate
  worktree_cleanup "$wt_path"
  if ! git worktree add "$wt_path" "${remote}/${branch}" -B "$branch" 2>&1; then
    return 1
  fi
  cd "$wt_path" || return 1
  git submodule update --init --recursive 2>/dev/null || true
  return 0
}

# worktree_cleanup PATH
# Removes a git worktree and clears the Claude Code project cache for it.
# Safe to call multiple times or on non-existent paths.
# Requires: PROJECT_REPO_ROOT (falls back to current directory).
worktree_cleanup() {
  local wt_path="$1"
  local repo_root="${PROJECT_REPO_ROOT:-$(pwd)}"
  cd "$repo_root" 2>/dev/null || true
  git worktree remove "$wt_path" --force 2>/dev/null || true
  rm -rf "$wt_path"
  _worktree_clear_claude_cache "$wt_path"
}

# worktree_cleanup_stale [MAX_AGE_HOURS]
# Scans /tmp for orphaned worktrees older than MAX_AGE_HOURS (default 24).
# Skips worktrees that have active tmux panes or are marked as preserved.
# Prunes dangling worktree references after cleanup.
# Requires: PROJECT_REPO_ROOT.
worktree_cleanup_stale() {
  local max_age_hours="${1:-24}"
  local max_age_seconds=$((max_age_hours * 3600))
  local now
  now=$(date +%s)
  local cleaned=0

  # Collect active tmux pane working directories for safety check
  local active_dirs=""
  active_dirs=$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null || true)

  local wt_dir
  for wt_dir in /tmp/*-worktree-* /tmp/action-*-[0-9]* /tmp/disinto-*; do
    [ -d "$wt_dir" ] || continue
    # Must be a git worktree (has .git file or directory)
    [ -f "$wt_dir/.git" ] || [ -d "$wt_dir/.git" ] || continue

    # Skip preserved worktrees
    [ -f "$wt_dir/.worktree-preserved" ] && continue

    # Check age (use directory mtime)
    local dir_mtime
    dir_mtime=$(stat -c %Y "$wt_dir" 2>/dev/null || echo "$now")
    local age=$((now - dir_mtime))
    [ "$age" -lt "$max_age_seconds" ] && continue

    # Skip if an active tmux pane is using this worktree
    if [ -n "$active_dirs" ] && echo "$active_dirs" | grep -qF "$wt_dir"; then
      continue
    fi

    # Remove the worktree and its Claude cache
    local repo_root="${PROJECT_REPO_ROOT:-$(pwd)}"
    git -C "$repo_root" worktree remove "$wt_dir" --force 2>/dev/null || rm -rf "$wt_dir"
    _worktree_clear_claude_cache "$wt_dir"
    log "cleaned stale worktree: ${wt_dir} (age: $((age / 3600))h)"
    cleaned=$((cleaned + 1))
  done

  # Prune any dangling worktree references
  git -C "${PROJECT_REPO_ROOT:-$(pwd)}" worktree prune 2>/dev/null || true

  [ "$cleaned" -gt 0 ] && log "cleaned ${cleaned} stale worktree(s)"
}

# worktree_preserve PATH REASON
# Marks a worktree as preserved for debugging. Preserved worktrees are skipped
# by worktree_cleanup_stale. The reason is written to a marker file inside
# the worktree directory.
worktree_preserve() {
  local wt_path="$1"
  local reason="${2:-unspecified}"
  if [ -d "$wt_path" ]; then
    printf '%s\n' "$reason" > "$wt_path/.worktree-preserved"
    log "PRESERVED worktree for debugging: ${wt_path} (reason: ${reason})"
  fi
}
