#!/usr/bin/env bash
# =============================================================================
# notices-drain.sh — host-side only, called by the healer (bin/healer.sh)
# under the AD-006 exception (#1970, #2032). Never source it from lib/ or an
# agent container.
#
# Usage: bin/notices-drain.sh DIR
#
# lib/notice.sh (#2031) queues owner messages as files under
# ${TAPE_DIR:-/srv/disinto/tape}/notices; the healer's tick sends that queue
# through the same sender the healer already uses, ${HEALER_NOTIFY_CMD}
# (bin/notify-owner.sh, Telegram). DIR is the contract: if it does not exist,
# nobody has queued anything — an agent must own the directory to write to it
# — so the drain exits 0 silently and creates nothing.
#
# The queue is the plain *.txt files directly in DIR (never DIR/sent/),
# oldest name first (sort), at most ${NOTICES_MAX_PER_TICK:-5} per run. Each
# file's whole content is passed to the notify command as one argument; its
# stderr goes to a temp file:
#   * rc 0 and stderr without "not configured": the notice was sent, so mv
#     the file to DIR/sent.
#   * rc 0 and stderr containing "not configured": the channel is not set up;
#     leave every file in place, print "notices-drain: not configured
#     (<count> waiting)" to stderr and exit 0. A missing channel never blocks
#     the healer.
#   * any other rc: the send failed; leave the file in place, print
#     "notices-drain: send failed (exit <rc>)" to stderr and exit 1. The rest
#     of the queue waits for the next tick.
#
# It never prints a file's text and never prints the notify command's stderr
# beyond its first line: the token lives in notify-owner.sh's URL, which that
# script already keeps off stderr. Does not source lib/env.sh (host-side, like
# notify-owner.sh); no set -x.
#
# Tests: tests/acceptance/issue-2032.sh.
# =============================================================================
set -euo pipefail
# Drop an inherited bash -x before any command string is expanded.
set +x

dir="${1:-}"

# DIR missing (or not a directory): nothing is queued, nothing to do, and the
# drain must not create the directory — an agent that needs the queue owns it.
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  exit 0
fi

max="${NOTICES_MAX_PER_TICK:-5}"
case "$max" in
  ''|*[!0-9]*) max=5 ;;
esac

# The queue: *.txt directly in DIR, oldest name first.
queue=()
while IFS= read -r line; do
  queue+=("$line")
done < <(find "$dir" -maxdepth 1 -type f -name '*.txt' | sort)

# At most max files per tick; the rest wait for the next one.
limit="${#queue[@]}"
if [ "$limit" -gt "$max" ]; then
  limit="$max"
fi

for ((i = 0; i < limit; i++)); do
  file="${queue[i]}"
  err="$(mktemp)"
  rc=0
  "${HEALER_NOTIFY_CMD:?}" "$(cat "$file")" 2>"$err" || rc=$?

  if [ "$rc" -eq 0 ]; then
    stderr="$(cat "$err")"
    rm -f "$err"
    case "$stderr" in
      *"not configured"*)
        # Every file is still in DIR (the sends before this one would have
        # moved to sent/, so they are not counted).
        waiting="$(find "$dir" -maxdepth 1 -type f -name '*.txt' | wc -l | tr -d ' ')"
        printf 'notices-drain: not configured (%s waiting)\n' "$waiting" >&2
        exit 0
        ;;
    esac
    mkdir -p "$dir/sent"
    mv "$file" "$dir/sent/"
  else
    # The notify command's stderr is not echoed at all: only the exit code
    # crosses to the healer.
    rm -f "$err"
    printf 'notices-drain: send failed (exit %s)\n' "$rc" >&2
    exit 1
  fi
done

exit 0
