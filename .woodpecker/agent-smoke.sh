#!/usr/bin/env bash
# .woodpecker/agent-smoke.sh — CI smoke test: syntax check + function resolution
#
# Checks:
#   1. bash -n syntax check on all .sh files in agent directories
#   2. Every custom function called by agent scripts is defined in lib/ or the script itself
#
# Fast (<10s): no network, no tmux, no Claude needed.

set -euo pipefail

cd "$(dirname "$0")/.."

# CI-side filesystem snapshot: show lib/ state at smoke time (#600)
echo "=== smoke environment snapshot ==="
ls -la lib/ 2>&1 | head -50
echo "=== "

FAILED=0

# ── helpers ─────────────────────────────────────────────────────────────────

# Extract function names defined in a bash script (top-level or indented).
# Uses awk instead of grep -Eo for busybox/Alpine compatibility (#296).
get_fns() {
  local f="$1"
  # Pure-awk implementation: avoids grep/sed cross-platform differences
  # (BusyBox grep BRE quirks, sed ; separator issues on Alpine).
  awk '
    /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_][a-zA-Z0-9_]*[[:space:]]*[(][)]/ {
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]*[(].*/, "", line)
      print line
    }
  ' "$f" 2>/dev/null | sort -u || true
}

# Extract call-position identifiers that look like custom function calls:
#   - strip comment lines
#   - split into statements by ; and $(
#   - strip leading shell keywords (if/while/! etc.) from each statement
#   - take the first word; skip if it looks like an assignment (var= or var =)
#   - keep only lowercase identifiers containing underscore
#   - skip if the identifier is followed by ) or : (case labels, Python patterns)
get_candidates() {
  local script="$1"
  awk '
    /^[[:space:]]*#/ { next }
    {
      n = split($0, parts, /;|\$\(/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        gsub(/^[[:space:]]+/, "", p)

        # Skip variable assignments (var= or var =value, including Python-style "var = value")
        if (p ~ /^[a-zA-Z_][a-zA-Z0-9_]* *=/) continue

        # Strip leading shell keywords and negation operator
        do {
          changed = 0
          if (p ~ /^(if|while|until|for|case|do|done|then|else|elif|fi|esac|!) /) {
            sub(/^[^ ]+ /, "", p)
            changed = 1
          }
        } while (changed)

        # Skip for-loop iteration variable ("varname in list")
        if (p ~ /^[a-zA-Z_][a-zA-Z0-9_]* in /) continue

        # Extract first word if it looks like a custom function (lowercase + underscore)
        if (match(p, /^[a-z][a-zA-Z0-9_]*_[a-zA-Z0-9_]+/)) {
          word = substr(p, RSTART, RLENGTH)
          rest = substr(p, RSTART + RLENGTH, 1)
          # Skip: function definitions (word(), case labels (word) or word|),
          #        Python/jq patterns (word:), object method calls (word.method),
          #        assignments (word=)
          if (rest == "(" || rest == ")" || rest == "|" || rest == ":" || rest == "." || rest == "=") continue
          print word
        }
      }
    }
  ' "$script" | sort -u || true
}

# ── 1. bash -n syntax check ──────────────────────────────────────────────────

echo "=== 1/2  bash -n syntax check ==="
while IFS= read -r -d '' f; do
  if ! bash -n "$f" 2>&1; then
    printf 'FAIL [syntax] %s\n' "$f"
    FAILED=1
  fi
done < <(find dev gardener review planner supervisor architect lib vault -name "*.sh" -print0 2>/dev/null)
echo "syntax check done"

# ── 2. Function-resolution check ─────────────────────────────────────────────

echo "=== 2/2  Function resolution ==="

# Required lib files for LIB_FUNS construction. Missing any of these means the
# checkout is incomplete or the test is misconfigured — fail loudly, do NOT
# silently produce a partial LIB_FUNS list (that masquerades as "undef" errors
# in unrelated scripts; see #600).
REQUIRED_LIBS=(
  lib/agent-sdk.sh lib/env.sh lib/ci-helpers.sh lib/load-project.sh
  lib/secret-scan.sh lib/formula-session.sh lib/mirrors.sh lib/guard.sh
  lib/pr-lifecycle.sh lib/issue-lifecycle.sh lib/worktree.sh
)

for f in "${REQUIRED_LIBS[@]}"; do
  if [ ! -f "$f" ]; then
    printf 'FAIL [missing-lib] expected %s but it is not present at smoke time\n' "$f" >&2
    printf '  pwd=%s\n' "$(pwd)" >&2
    printf '  ls lib/=%s\n' "$(ls lib/ 2>&1 | tr '\n' ' ')" >&2
    echo '=== SMOKE TEST FAILED (precondition) ===' >&2
    exit 2
  fi
done

# Functions provided by shared lib files (available to all agent scripts via source).
#
# Included — these are inline-sourced by agent scripts:
#   lib/env.sh              — sourced by every agent (log, forge_api, etc.)
#   lib/agent-sdk.sh        — sourced by SDK agents (agent_run, agent_recover_session)
#   lib/ci-helpers.sh       — sourced by pollers and review (ci_passed, classify_pipeline_failure, etc.)
#   lib/load-project.sh     — sourced by env.sh when PROJECT_TOML is set
#   lib/secret-scan.sh      — standalone CLI tool, run directly (not sourced)
#   lib/formula-session.sh  — sourced by formula-driven agents (acquire_run_lock, check_memory, etc.)
#   lib/mirrors.sh          — sourced by merge sites (mirror_push)
#   lib/guard.sh            — sourced by all polling-loop entry points (check_active)
#   lib/issue-lifecycle.sh  — sourced by agents for issue claim/release/block/deps
#   lib/worktree.sh         — sourced by agents for worktree create/recover/cleanup/preserve
#
# Excluded — not sourced inline by agents:
#   lib/tea-helpers.sh      — sourced conditionally by env.sh (tea_file_issue, etc.); checked standalone below
#   lib/ci-debug.sh         — standalone CLI tool, run directly (not sourced)
#   lib/parse-deps.sh       — executed via `bash lib/parse-deps.sh` (not sourced)
#   lib/hooks/*.sh          — Claude Code hook scripts, executed by the harness (not sourced)
#
# If a new lib file is added and sourced by agents, add it to LIB_FUNS below
# and add a check_script call for it in the lib files section further down.
LIB_FUNS=$(
  for f in "${REQUIRED_LIBS[@]}"; do get_fns "$f"; done | sort -u
)

# Known external commands and shell builtins — never flag these
# (shell keywords are quoted to satisfy shellcheck SC1010)
KNOWN_CMDS=(
  awk bash break builtin cat cd chmod chown claude command continue
  cp curl cut date declare 'do' 'done' elif else eval exit export
  false 'fi' find flock for getopts git grep gzip gunzip head hash
  'if' jq kill local ln ls mapfile mkdir mktemp mv nc pgrep printf
  python3 python read readarray return rm sed set sh shift sleep
  sort source stat tail tar tea test 'then' tmux touch tr trap true type
  unset until wait wc while which xargs
)

is_known_cmd() {
  local fn="$1"
  for k in "${KNOWN_CMDS[@]}"; do
    [ "$fn" = "$k" ] && return 0
  done
  return 1
}

# check_script SCRIPT [EXTRA_DEFINITION_SOURCES...]
# Checks that every custom function called by SCRIPT is defined in:
#   - SCRIPT itself
#   - Any EXTRA_DEFINITION_SOURCES (for cross-sourced scripts)
#   - The shared lib files (LIB_FUNS)
check_script() {
  local script="$1"
  shift
  [ -f "$script" ] || { printf 'SKIP (not found): %s\n' "$script"; return; }

  # Collect all function definitions available to this script
  local all_fns
  all_fns=$(
    {
      printf '%s\n' "$LIB_FUNS"
      get_fns "$script"
      for extra in "$@"; do
        if [ -f "$extra" ]; then get_fns "$extra"; fi
      done
    } | sort -u
  )

  local candidates
  candidates=$(get_candidates "$script")

  while IFS= read -r fn; do
    [ -z "$fn" ] && continue
    is_known_cmd "$fn" && continue
    if ! printf '%s\n' "$all_fns" | grep -qxF "$fn"; then
      printf 'FAIL [undef] %s: %s\n' "$script" "$fn"
      # Diagnostic dump (#600): if the function is expected to be in a known lib,
      # print what the actual all_fns set looks like so we can tell whether the
      # function is genuinely missing or whether the resolution loop is broken.
      printf '  all_fns count: %d\n' "$(printf '%s\n' "$all_fns" | wc -l)"
      printf '  LIB_FUNS contains "%s": %s\n' "$fn" "$(printf '%s\n' "$LIB_FUNS" | grep -cxF "$fn")"
      printf '  defining lib (if any): %s\n' "$(grep -l "^[[:space:]]*${fn}[[:space:]]*()" lib/*.sh 2>/dev/null | tr '\n' ' ')"
      FAILED=1
    fi
  done <<< "$candidates"
}

# Inline-sourced lib files — check that their own function calls resolve.
# These are already in LIB_FUNS (their definitions are available to agents),
# but this verifies calls *within* each lib file are also resolvable.
check_script lib/env.sh              lib/mirrors.sh
check_script lib/agent-sdk.sh
check_script lib/ci-helpers.sh
check_script lib/secret-scan.sh
check_script lib/tea-helpers.sh         lib/secret-scan.sh
check_script lib/formula-session.sh
check_script lib/load-project.sh
check_script lib/mirrors.sh              lib/env.sh
check_script lib/guard.sh
check_script lib/pr-lifecycle.sh
check_script lib/issue-lifecycle.sh   lib/secret-scan.sh

# Standalone lib scripts (not sourced by agents; run directly or as services).
# Still checked for function resolution against LIB_FUNS + own definitions.
check_script lib/ci-debug.sh
check_script lib/parse-deps.sh

# Agent scripts — list cross-sourced files where function scope flows across files.
check_script dev/dev-agent.sh
check_script dev/dev-poll.sh
check_script dev/phase-test.sh
check_script gardener/gardener-run.sh    lib/formula-session.sh
check_script review/review-pr.sh         lib/agent-sdk.sh
check_script review/review-poll.sh
check_script planner/planner-run.sh      lib/formula-session.sh
check_script supervisor/supervisor-poll.sh
check_script supervisor/update-prompt.sh
check_script supervisor/supervisor-run.sh  lib/formula-session.sh
check_script supervisor/preflight.sh
check_script predictor/predictor-run.sh
check_script architect/architect-run.sh

echo "function resolution check done"

if [ "$FAILED" -ne 0 ]; then
  echo "=== SMOKE TEST FAILED ==="
  exit 1
fi
echo "=== SMOKE TEST PASSED ==="
