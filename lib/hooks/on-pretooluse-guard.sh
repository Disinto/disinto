#!/bin/bash
# on-pretooluse-guard.sh — PreToolUse hook: guard destructive operations.
#
# Called by Claude Code before executing a Bash command in agent sessions.
# Blocks:
# - git push --force / -f to primary branch
# - rm -rf targeting paths outside the worktree
# - Direct Codeberg API merge calls (should go through phase protocol)
# - Direct issue close calls (should go through phase protocol)
# - git checkout / git switch to primary branch (stay on feature branch)
# - FACTORY_ROOT access from worktrees (formula agents exempted)
# - System commands (kill, docker, tmux) outside supervisor sessions
#
# Usage (in .claude/settings.json):
#   {"type":"command","command":"this-script <primary_branch> <worktree_path> [session_name]"}
#
# Args: $1 = primary branch (default: main), $2 = worktree absolute path,
#       $3 = session name (optional — used to detect formula agents)
#
# Exit 0: allow (tool proceeds)
# Exit 2: deny (reason on stdout — Claude sees it and can self-correct)

primary_branch="${1:-main}"
worktree_path="${2:-}"
session_name="${3:-}"

# Detect formula sessions by session name prefix.
# Formula agents (supervisor, gardener, planner, predictor) need read access
# to FACTORY_ROOT for env.sh, AGENTS.md, formulas/, lib/.
# Supervisor additionally needs write access for system commands.
is_formula=false
is_supervisor=false
case "$session_name" in
  supervisor-*) is_formula=true; is_supervisor=true ;;
  gardener-*|planner-*|predictor-*) is_formula=true ;;
esac

# Resolve FACTORY_ROOT (parent of lib/hooks/ where this script lives)
factory_root="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)"

input=$(cat)

# Extract the command string from hook JSON
command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$command_str" ] && exit 0

# --- Guard 1: force push to primary branch ---
# Also blocks bare "git push --force" (no branch arg) since the upstream
# tracking branch might point to the primary branch.
if printf '%s' "$command_str" | grep -qE '\bgit\s+push\b' \
   && printf '%s' "$command_str" | grep -qE '(--force|--force-with-lease|\s-[a-zA-Z]*f)\b'; then
  if printf '%s' "$command_str" | grep -qw "$primary_branch"; then
    printf 'BLOCKED: Force-pushing to %s is not allowed. Push to your feature branch instead.\n' "$primary_branch"
    exit 2
  fi
  # Bare force push with no explicit branch — could target primary via upstream
  if ! printf '%s' "$command_str" | grep -qE '\bgit\s+push\s+\S+\s+\S'; then
    printf 'BLOCKED: Bare force-push without an explicit branch is not allowed (upstream may point to %s). Specify your feature branch: git push --force-with-lease origin <branch>\n' "$primary_branch"
    exit 2
  fi
fi

# --- Guard 2: rm -rf outside worktree ---
if [ -n "$worktree_path" ] \
   && printf '%s' "$command_str" | grep -qE '\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)\b'; then
  # Extract absolute paths from the command
  abs_paths=$(printf '%s' "$command_str" | grep -oE "/[^[:space:];|&>\"']+" || true)
  if [ -n "$abs_paths" ]; then
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      case "$p" in
        "${worktree_path}"/*|"${worktree_path}") ;;  # Inside worktree — allow
        /tmp/*|/tmp) ;;   # Temp files — allow (agents use /tmp for scratch)
        /dev/*) ;;        # Device paths — allow
        "${factory_root}"/*|"${factory_root}")
          # Formula agents may clean up inside FACTORY_ROOT; others are blocked
          if ! "$is_formula"; then
            printf 'BLOCKED: rm -rf targets %s which is outside the worktree (%s). Only delete files within your worktree.\n' "$p" "$worktree_path"
            exit 2
          fi
          ;;
        *)
          printf 'BLOCKED: rm -rf targets %s which is outside the worktree (%s). Only delete files within your worktree.\n' "$p" "$worktree_path"
          exit 2
          ;;
      esac
    done <<< "$abs_paths"
  fi
fi

# --- Guard 3: Direct Codeberg API merge calls ---
if printf '%s' "$command_str" | grep -qE '/pulls/[0-9]+/merge'; then
  printf 'BLOCKED: Direct API merge calls must go through the phase protocol. Push your changes and write PHASE:awaiting_ci — the orchestrator handles merges.\n'
  exit 2
fi

# --- Guard 5: Direct issue close calls ---
# Defense in depth: Claude should never close issues directly — the orchestrator
# closes issues after a successful merge via the phase protocol.
if printf '%s' "$command_str" | grep -qE '/issues/[0-9]+.*state.*closed'; then
  printf 'BLOCKED: Closing issues must go through the phase protocol. Write PHASE:done — the orchestrator closes issues after merge.\n'
  exit 2
fi

# --- Guard 4: checkout/switch to primary branch ---
# Blocks: git checkout main, git switch main, git switch --detach main, etc.
# Allows: git checkout -b branch main, git checkout -- file
escaped_branch=$(printf '%s' "$primary_branch" | sed 's/[.[\*^$()+?{|]/\\&/g')
if printf '%s' "$command_str" | grep -qE "\bgit\s+(checkout|switch)\s+(-[^ ]+\s+)*${escaped_branch}\b" \
   && ! printf '%s' "$command_str" | grep -qE '(\s--\s|\s-[bBcC]\s)'; then
  printf 'BLOCKED: Switching to %s is not allowed. Stay on your feature branch.\n' "$primary_branch"
  exit 2
fi

# --- Guard 6: FACTORY_ROOT access from worktrees ---
# Formula agents (supervisor, gardener, planner, predictor) run in worktrees
# but need to read FACTORY_ROOT for env.sh, AGENTS.md, formulas/, lib/.
# Dev/review/action agents must stay inside their worktree.
# Only matches commands that actually access the filesystem (cd, source, cat,
# ls, etc.) — not strings that merely mention the path (e.g. in commit messages).
if [ -n "$worktree_path" ] && [ -n "$factory_root" ] \
   && [ "$worktree_path" != "$factory_root" ]; then
  escaped_fr=$(printf '%s' "$factory_root" | sed 's/[.[\*^$()+?{|\/]/\\&/g')
  if printf '%s' "$command_str" | grep -qE "(^|\s|&&|\|\||;)(cd|source|\.|\bcat\b|\bls\b|\bread\b|\bhead\b|\btail\b|\bcp\b|\bmv\b)\s+[\"']?${escaped_fr}"; then
    if ! "$is_formula"; then
      printf 'BLOCKED: Accessing %s is not allowed from worktree sessions. Use files within your worktree (%s) instead.\n' "$factory_root" "$worktree_path"
      exit 2
    fi
  fi
fi

# --- Guard 7: system commands restricted to supervisor ---
# Only the supervisor session may run system management commands (kill, docker,
# tmux send-keys/kill-session).  Other agents — including other formula agents —
# must not manage host processes.
if ! "$is_supervisor"; then
  if printf '%s' "$command_str" | grep -qE '\b(kill\s+-[0-9A-Z]|\bkill\s+[0-9]|docker\s+(prune|rm|stop|kill)|tmux\s+(kill-session|send-keys))\b'; then
    printf 'BLOCKED: System management commands (kill, docker, tmux) are only allowed in supervisor sessions.\n'
    exit 2
  fi
fi

exit 0
