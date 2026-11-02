#!/usr/bin/env bash
# =============================================================================
# notice.sh — queue a message for the owner as a file (#2031)
#
# The proposal loop (docs/design/proposal-loop.md §3) wants the owner told on
# every approval and on the first grade above 0.5. AD-006 says the messaging
# token lives in the healer job alone and nothing under lib/ sends it: an
# agent may only write a queue file. Every agent job mounts the tape volume
# read-write at /srv/disinto/tape and the healer runs with TAPE_DIR set there,
# so a file queue under the tape is a channel the healer (bin/healer.sh) can
# drain through bin/notices-drain.sh (#2032). This lib never sends anything:
# it writes files and nothing else.
#
# Public (sourced; pure bash, does not source lib/env.sh):
#   notice_owner TEXT
#     -> queue one owner notice. Directory:
#        ${NOTICES_DIR:-${TAPE_DIR:-/srv/disinto/tape}/notices}, created with
#        mkdir -p. The first 4000 characters of TEXT (the cap the sender
#        applies) are written to a temp file inside that
#        directory, then mv'd to <epoch-seconds>-<pid>-<RANDOM>.txt in the
#        same directory, so the sender never reads a half-written file.
#        Return 0 when the file is in place; return 1 with exactly one stderr
#        line when TEXT is empty or the directory or the write fails. Prints
#        nothing on success, never prints TEXT, never sends anything.
#
# Env seams:
#   NOTICES_DIR  notices directory; overrides the TAPE_DIR-derived default.
#   TAPE_DIR     the tape volume (default /srv/disinto/tape); the notices
#                directory is <tape>/notices when NOTICES_DIR is unset.
#
# Tests: tests/acceptance/issue-2031.sh.
# =============================================================================
set -euo pipefail

notice_owner() {
  local text="${1:-}"
  local notices_dir="${NOTICES_DIR:-${TAPE_DIR:-/srv/disinto/tape}/notices}"

  if [ -z "$text" ]; then
    echo "notice_owner: empty text, nothing queued" >&2
    return 1
  fi

  if ! mkdir -p "$notices_dir" 2>/dev/null; then
    echo "notice_owner: cannot create notices dir: $notices_dir" >&2
    return 1
  fi

  # The temp file lives in the same directory as the final name, so the mv is
  # a rename: the sender either sees nothing or a complete notice.
  local tmp="$notices_dir/.notice-$$.tmp"
  local epoch
  epoch="$(date -u +%s)"
  local target="$notices_dir/$epoch-$$-${RANDOM}.txt"

  # 2>/dev/null comes first: if the output redirect itself fails (read-only
  # dir), bash's own error lands on the already-discarded stderr, leaving
  # exactly the diagnostic line below.
  if ! printf '%s' "${text:0:4000}" 2>/dev/null >"$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "notice_owner: cannot write notice: $notices_dir" >&2
    return 1
  fi
  if ! mv "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    echo "notice_owner: cannot move notice into place: $notices_dir" >&2
    return 1
  fi
  return 0
}
