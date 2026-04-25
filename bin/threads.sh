#!/usr/bin/env bash
# =============================================================================
# threads.sh — Persistent thread store helpers
#
# Subcommands:
#   threads list          — print all threads, newest first, with status
#   threads show <task>   — print meta.json + tail of stream.jsonl for a thread
#   threads gc            — delete completed threads older than 7 days
#
# Environment:
#   THREADS_ROOT  — parent directory for thread stores (default /var/lib/disinto/threads)
#   THREADS_TTL   — retention in days for gc (default 7)
# =============================================================================
set -euo pipefail

THREADS_ROOT="${THREADS_ROOT:-/var/lib/disinto/threads}"
THREADS_TTL="${THREADS_TTL:-7}"

usage() {
  printf 'Usage: %s {list|show <task-id>|gc}\n' "$0"
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
  if [ ! -d "$THREADS_ROOT" ]; then
    return 0
  fi

  local now
  now="$(date +%s)"

  # Print header
  printf '%-20s %-12s %-28s %s\n' "TASK-ID" "STATUS" "STARTED" "QUERY"

  for thread_dir in "$THREADS_ROOT"/*/; do
    [ -d "$thread_dir" ] || continue

    local meta_path="$thread_dir/meta.json"
    [ -f "$meta_path" ] || continue

    local task_id status started query
    task_id="$(basename "$thread_dir")"
    status="$(jq -r '.status // "unknown"' "$meta_path" 2>/dev/null || echo "unknown")"
    started="$(jq -r '.started // "n/a"' "$meta_path" 2>/dev/null || echo "n/a")"
    query="$(jq -r '(.query // "")[:50]' "$meta_path" 2>/dev/null || echo "")"

    printf '%-20s %-12s %-28s %s\n' "$task_id" "$status" "$started" "$query"
  done
}

# ── show ──────────────────────────────────────────────────────────────────────
cmd_show() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then
    echo "ERROR: task-id required" >&2
    usage
    return 1
  fi

  local meta_path="$THREADS_ROOT/$task_id/meta.json"
  if [ ! -f "$meta_path" ]; then
    echo "ERROR: no thread found for task-id '$task_id'" >&2
    return 1
  fi

  echo "=== meta.json ==="
  cat "$meta_path"
  echo ""

  local stream_path="$THREADS_ROOT/$task_id/stream.jsonl"
  if [ -f "$stream_path" ]; then
    echo "=== stream.jsonl (last 20 lines) ==="
    tail -n 20 "$stream_path"
    echo ""
  fi
}

# ── gc ────────────────────────────────────────────────────────────────────────
cmd_gc() {
  if [ ! -d "$THREADS_ROOT" ]; then
    echo "No threads directory at $THREADS_ROOT — nothing to do."
    return 0
  fi

  local now
  now="$(date +%s)"

  local deleted=0
  local kept=0

  for thread_dir in "$THREADS_ROOT"/*/; do
    [ -d "$thread_dir" ] || continue

    local meta_path="$thread_dir/meta.json"
    [ -f "$meta_path" ] || continue

    local task_id status started
    task_id="$(basename "$thread_dir")"
    status="$(jq -r '.status // "unknown"' "$meta_path" 2>/dev/null || echo "unknown")"
    started="$(jq -r '.started // ""' "$meta_path" 2>/dev/null || echo "")"

    # Only collect completed threads
    case "$status" in
      completed|failed|error) ;;
      *)
        kept=$(( kept + 1 ))
        continue
        ;;
    esac

    # Check age — skip if younger than TTL
    if [ -n "$started" ] && [ "$started" != "null" ]; then
      local start_epoch
      start_epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
      if [ "$(( now - start_epoch ))" -lt "$(( THREADS_TTL * 86400 ))" ]; then
        kept=$(( kept + 1 ))
        continue
      fi
    fi

    rm -rf "$thread_dir"
    deleted=$(( deleted + 1 ))
  done

  printf 'gc: deleted %d, kept %d\n' "$deleted" "$kept"
}

# ── main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
  list)   cmd_list ;;
  show)   cmd_show "${2:-}" ;;
  gc)     cmd_gc ;;
  *)      usage; exit 1 ;;
esac
