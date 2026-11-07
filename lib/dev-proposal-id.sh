#!/usr/bin/env bash
# dev-proposal-id.sh — a dev attempt keeps its proposal id across a container
# restart (#2170)
#
# The pick stores its proposal id only in /tmp (the #1398 id file). A merge
# that touches docker/agents/ rebuilds the agents image and restarts every
# agent job, emptying /tmp; the attempt then loses its id and the outcome is
# keyed to a fresh ULID, so the tape holds no outcome for the decision.
# The tape is append-only and holds every dev proposal, so it can rebuild
# the file.
#
# dev_proposal_id ISSUE
#   1. If /tmp/dev-proposal-id-${PROJECT_NAME:-default}-<issue> holds a
#      non-empty id, echo it and return 0. The tape is never read.
#   2. Otherwise read ${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl and find the
#      newest record with type "proposal", loop "dev" and
#      (.ref | tostring) == ISSUE (append order is time order).
#   3. Use it only when the tape holds no outcome for that id with
#      bits.merged or bits.rejected equal to 1 or true. A failed outcome
#      (merged 0, not rejected) does not end a proposal: #1441 re-picks reuse
#      it and #1646 counts those failures. A merged or rejected proposal stays
#      closed, so a reopened issue gets a fresh pick, as it would today with
#      an empty /tmp.
#   4. On a hit: write the id to the id file; write the proposal's `t` as
#      epoch seconds to /tmp/dev-proposal-started-${PROJECT_NAME:-default}-<issue>
#      unless that file already holds an integer, so proposal_elapsed_s
#      (lib/tape.sh) measures from the pick; log the recovery line; echo the id.
#   5. No hit, or an unreadable tape: echo nothing and return 0 — what the
#      callers already handle.
#
# Tape records carry no project field, and this factory runs one project, so
# the lookup matches on `loop` and `ref` only.
#
# Hermetic: jq and date only. No network, no forge, no agent.

set -euo pipefail

# dev_proposal_id ISSUE — echo the dev proposal id for ISSUE, recovering it
# from the tape when the /tmp id file is missing or empty. See the header.
dev_proposal_id() {
  local ISSUE="${1:-}"
  # Project-scoped exactly like the #1398 writer in dev-poll.sh, so two
  # projects sharing a /tmp can't clobber each other's ids.
  local id_file="/tmp/dev-proposal-id-${PROJECT_NAME:-default}-${ISSUE}"
  local started_file="/tmp/dev-proposal-started-${PROJECT_NAME:-default}-${ISSUE}"
  local id=""

  # 1. The id file wins: a present, non-empty id never touches the tape.
  if [ -f "$id_file" ]; then
    id="$(cat "$id_file" 2>/dev/null)" || id=""
    if [ -n "$id" ]; then
      printf '%s\n' "$id"
      return 0
    fi
  fi

  # 2-3. Rebuild from the tape. jq -c prints the one matching proposal, or
  # nothing (rc 0) when there is no open dev proposal for the issue; a
  # malformed/unreadable tape exits non-zero and yields an empty rec.
  local tape="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"
  local rec="" proposal_id="" started="" epoch=""
  if [ -f "$tape" ]; then
    rec="$(jq -cs --arg issue "$ISSUE" '
      . as $records
      | ( [ $records[]
            | select(.type == "proposal" and .loop == "dev"
                     and ((.ref | tostring) == $issue)) ]
          | last ) as $p
      | if $p == null or $p.id == null
          then empty
          elif any($records[]; .type == "outcome"
                   and .proposal_id == $p.id
                   and (.bits.merged == 1 or .bits.merged == true
                        or .bits.rejected == 1 or .bits.rejected == true))
          then empty
          else $p
          end
    ' "$tape" 2>/dev/null)" || rec=""
  fi

  proposal_id="$(printf '%s' "$rec" | jq -r '.id // empty' 2>/dev/null)" \
    || proposal_id=""
  if [ -z "$proposal_id" ]; then
    # No recoverable proposal (or no tape): callers handle the empty id.
    return 0
  fi

  # 4. Rewrite the id file so every later reader hits the fast path.
  printf '%s' "$proposal_id" > "$id_file" 2>/dev/null || true

  # The started file: the pick's epoch, unless it already holds one. busybox
  # date (alpine CI) parses ISO 8601 with -d but not `-d -`, so pass the
  # timestamp as an argument.
  started="$(cat "$started_file" 2>/dev/null)" || started=""
  if ! [[ "$started" =~ ^[0-9]+$ ]]; then
    epoch="$(jq -r '.t // empty' <<< "$rec" 2>/dev/null)" || epoch=""
    if [ -n "$epoch" ]; then
      epoch="$(date -u -d "$epoch" +%s 2>/dev/null)" || epoch=""
      if [ -n "$epoch" ]; then
        printf '%s' "$epoch" > "$started_file" 2>/dev/null || true
      fi
    fi
  fi

  log "tape: recovered proposal id ${proposal_id} for #${ISSUE} from the tape (id file missing)"
  printf '%s\n' "$proposal_id"
  return 0
}
