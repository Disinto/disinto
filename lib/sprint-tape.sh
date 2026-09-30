#!/usr/bin/env bash
# sprint-tape.sh — sprint (Forgejo milestone) tape proposal (#1618)
#
# Sprints never reach the tape: dev proposals are per-issue and there is no
# sprint-level loop, so nothing can be graded at sprint level. A sprint is a
# Forgejo milestone; the tape needs exactly one `sprint`-loop proposal per
# milestone — created once, found without scanning the tape (id file under
# $TAPE_DIR/sprints/). The sprint's class is its nature (deploy, experiment,
# internal), read by the caller from the milestone's sprint block and passed
# through here.
#
# Function (sourced; no callers yet):
#   sprint_proposal_id MILESTONE_ID CLASS
#     -> <proposal-id>
#       * Id file ${TAPE_DIR}/sprints/<MILESTONE_ID>: if it holds an id, print
#         it and return 0 (no append). An empty file counts as absent (same
#         convention as emit_tape_proposal's re-pick guard, #1441).
#       * Otherwise take an exclusive flock on ${TAPE_DIR}/sprints/.lock,
#         check again (a concurrent call may have written the id file since
#         the first check), mint a fresh id the same way
#         emit_tape_proposal (dev/dev-poll.sh) does (uuidgen -> kernel uuid),
#         and call:
#             tape_proposal "$id" sprint "$class" "" "" '{}' '' "approved"
#             "milestone:<MILESTONE_ID>"
#         — no forecast (there is nothing to predict yet).
#       * class: CLASS when it matches ^[a-z][a-z0-9-]*$, otherwise "unclassed".
#       * The id file is written only after tape_proposal succeeds, then the
#         id is printed and 0 returned.
#       * Non-integer MILESTONE_ID or append failure: print nothing, return 1,
#         write no id file.
#
# Subsystems (sourced):
#   tape.sh     — append-only tape writers (#1389)

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/tape.sh"

# sprint_proposal_id MILESTONE_ID CLASS — idempotent mint of the proposal id
# for the milestone's sprint. Returns 0 printing the id on success (fresh
# mint or reuse of the persisted id); returns 1 (no output, no id file) when
# the milestone id is non-integer or the tape append fails.
sprint_proposal_id() {
  local milestone_id="${1:-}" class="${2:-}" rc=0
  local id_dir id_file lock_file existing

  # Non-integer milestone id: nothing to mint, nothing to write.
  if ! [[ "$milestone_id" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  id_dir="${TAPE_DIR}/sprints"
  id_file="${id_dir}/${milestone_id}"
  lock_file="${id_dir}/.lock"

  # The lock file needs its parent; mkdir -p is idempotent, so the race on it
  # between concurrent callers is harmless.
  if ! mkdir -p "$id_dir"; then
    return 1
  fi

  # Fast path (no lock): a persisted id means the milestone is already on the
  # tape — print it, no append.
  if [ -f "$id_file" ]; then
    existing="$(cat "$id_file" 2>/dev/null || true)"
    if [ -n "$existing" ]; then
      printf '%s\n' "$existing"
      return 0
    fi
  fi

  # Serialize the mint under an exclusive flock so two concurrent callers for
  # the same milestone never append two proposals: re-check under the lock,
  # mint one id, append, then — and only then — write the id file.
  (
    set -euo pipefail
    flock -x 9

    # Re-check under the lock: another caller may have written the id file
    # since we checked above.
    existing="$(cat "$id_file" 2>/dev/null || true)"
    if [ -n "$existing" ]; then
      printf '%s\n' "$existing"
      exit 0
    fi

    # Fresh id, the same way as emit_tape_proposal (dev/dev-poll.sh):
    # uuidgen when present, kernel uuid otherwise.
    id="$(uuidgen 2>/dev/null)" || id=""
    if [ -z "$id" ]; then
      id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || id=""
    fi
    if [ -z "$id" ]; then
      echo "sprint-tape: no uuid generator available — proposal not minted " \
        "for milestone ${milestone_id}" >&2
      exit 1
    fi

    # class: the caller's CLASS when it matches the class shape, otherwise
    # "unclassed".
    if [[ "$class" =~ ^[a-z][a-z0-9-]*$ ]]; then
      effective_class="$class"
    else
      effective_class="unclassed"
    fi

    # One sprint proposal per milestone, no forecast. The id file is written
    # only after a successful append so a failed append never persists an
    # id for a proposal that is not on the tape.
    if tape_proposal "$id" sprint "$effective_class" "" "" '{}' '' \
        "approved" "milestone:${milestone_id}"; then
      printf '%s\n' "$id" > "$id_file"
      printf '%s\n' "$id"
      exit 0
    fi

    echo "sprint-tape: tape append failed for milestone ${milestone_id} — " \
      "no id file written" >&2
    exit 1
  ) 9>"$lock_file" || rc=$?

  return "$rc"
}
