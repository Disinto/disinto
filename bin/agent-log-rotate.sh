#!/usr/bin/env bash
# =============================================================================
# agent-log-rotate.sh — Size-based log rotation for agent data directories
#
# Rotates every *.log under the agent-data root dirs (default glob
# /srv/disinto/agent-data*/ — covers agent-data, agent-data-qwen,
# agent-data-gardener, agent-data-opus-*, …) when the file exceeds
# LOG_MAX_SIZE_MB (default 50MB), keeping LOG_KEEP_GENERATIONS (default 5)
# gzip-compressed generations: <name>.1.gz … <name>.<N>.gz (oldest dropped).
#
# Rotation is copytruncate-style: the file is copied to <name>.1, the copy
# is gzipped, and the original is truncated in place (`: > file`). Truncating
# preserves the inode, so writers holding the file open with O_APPEND (the
# agent shell scripts append via `>>`) keep writing to the same file — no fd
# invalidation, no process restart needed. The cost is the standard
# copytruncate window: bytes appended between the copy and the truncate are
# lost.
#
# Runs as a Nomad periodic batch job (nomad/jobs/agent-logs-rotate.hcl) on
# the raw_exec driver — the task runs directly on the host, so the script
# operates on host paths with no container or volume mounts (same pattern as
# the snapshot-daemon raw_exec task in nomad/jobs/edge.hcl).
#
# Environment:
#   AGENT_DATA_GLOB      — glob of agent-data root dirs to scan
#                          (default: /srv/disinto/agent-data*)
#   LOG_MAX_SIZE_MB      — rotate files strictly larger than this, in MB
#                          (default: 50)
#   LOG_KEEP_GENERATIONS — compressed generations to keep (default: 5)
#
# Exit codes:
#   0  success (including "nothing to rotate")
#   1  bad environment or rotation failure
# =============================================================================
set -euo pipefail

AGENT_DATA_GLOB="${AGENT_DATA_GLOB:-/srv/disinto/agent-data*}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-50}"
LOG_KEEP_GENERATIONS="${LOG_KEEP_GENERATIONS:-5}"

log() { printf '[agent-log-rotate] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ── Environment validation ────────────────────────────────────────────────────
case "$LOG_MAX_SIZE_MB" in
  ''|*[!0-9]*) die "LOG_MAX_SIZE_MB must be a positive integer, got: '$LOG_MAX_SIZE_MB'" ;;
esac
case "$LOG_KEEP_GENERATIONS" in
  ''|*[!0-9]*) die "LOG_KEEP_GENERATIONS must be a positive integer, got: '$LOG_KEEP_GENERATIONS'" ;;
esac
[ "$LOG_MAX_SIZE_MB" -gt 0 ] || die "LOG_MAX_SIZE_MB must be > 0"
[ "$LOG_KEEP_GENERATIONS" -ge 1 ] || die "LOG_KEEP_GENERATIONS must be >= 1"

MAX_SIZE_BYTES=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))

# ── Rotation ──────────────────────────────────────────────────────────────────

# rotate_file FILE — shift generations up by one (dropping the oldest),
# then copytruncate FILE into FILE.1.gz.
rotate_file() {
  local f="$1"
  local i
  for (( i = LOG_KEEP_GENERATIONS - 1; i >= 1; i-- )); do
    if [ -f "$f.$i.gz" ]; then
      mv -f "$f.$i.gz" "$f.$(( i + 1 )).gz"
    fi
  done
  cp "$f" "$f.1"
  gzip -f "$f.1"
  : > "$f"
  log "rotated: $f → ${f##*/}.1.gz ($(du -h "$f.1.gz" | cut -f1))"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Expand the glob into a list of root dirs (compgen -G avoids the
# word-splitting/globbing issue of an unquoted expansion under set -u).
roots=()
while IFS= read -r d; do
  [ -n "$d" ] && roots+=("$d")
done < <(compgen -G "$AGENT_DATA_GLOB" 2>/dev/null || true)

if [ "${#roots[@]}" -eq 0 ]; then
  log "no agent-data dirs matched '$AGENT_DATA_GLOB' — nothing to do"
  exit 0
fi

rotated=0
checked_roots=0
for root in "${roots[@]}"; do
  [ -d "$root" ] || continue
  checked_roots=$(( checked_roots + 1 ))
  while IFS= read -r -d '' f; do
    rotate_file "$f"
    rotated=$(( rotated + 1 ))
  done < <(find "$root" -type f -name '*.log' -size "+${MAX_SIZE_BYTES}c" -print0)
done

if [ "$checked_roots" -eq 0 ]; then
  log "no agent-data dirs found under '$AGENT_DATA_GLOB' — nothing to do"
  exit 0
fi

log "done: rotated $rotated file(s) across $checked_roots dir(s) (threshold ${LOG_MAX_SIZE_MB}MB, keep ${LOG_KEEP_GENERATIONS} generations)"
