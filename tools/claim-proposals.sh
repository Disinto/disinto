#!/usr/bin/env bash
# =============================================================================
# tools/claim-proposals.sh — a merged claim becomes a claim-loop proposal (#1641)
#
# A claim is admitted by a human merge in the ops repo. Each revision of a
# claim is a new proposal in the claim loop (proposal-loop design §6), so
# checks and verdicts have a record to pair with. This tool is that writer.
# It does not retire a claim: a deleted claim file gets nothing — retiring a
# claim is its merge.
#
# For each id from claim_ids (lib/claims.sh, #1640):
#   * claim_valid fails: one log line, skip. An invalid file is not a proposal.
#   * sha = sha256 of the claim file. Skip when
#     ${TAPE_DIR}/claims/<id>.<sha> exists: this revision already has a proposal.
#   * Store the file with tape_payload, mint a fresh id the same way
#     emit_tape_proposal (dev/dev-poll.sh) does (uuidgen -> kernel uuid), and
#     append
#       tape_proposal "$pid" claim "<class>" "" "" '{}' "" approved
#       "claims/<id>.toml" '["<hash>"]'
#     (10th argument, #1634). A failed payload store passes no 10th argument.
#   * Only after the append succeeds, write $pid to
#     ${TAPE_DIR}/claims/<id>.<sha> and to ${TAPE_DIR}/claims/<id>.current.
#
# A uuid or append failure leaves no id file (the next run retries that
# revision) and makes this tool exit non-zero. The gardener treats that as a
# warning; it never fails the run.
#
# Usage:
#   tools/claim-proposals.sh
#
# Environment (all optional; the test seam):
#   CLAIMS_DIR  claim TOML dir (default ${OPS_REPO_ROOT}/claims, lib/claims.sh)
#   TAPE_DIR    tape directory (default /srv/disinto/tape, lib/tape.sh)
#   PAYLOAD_DIR content-addressed payloads (default /srv/disinto/tape/payloads)
#
# Exit codes:
#   0  every listed claim was proposed or skipped (invalid, already proposed,
#      or deleted)
#   1  a revision could not be minted or appended — no id file for that one
#
# Hermetic aside from the tape and claim dirs it is pointed at. No network,
# no agent, no secrets (AD-006). Does not source lib/env.sh: the gardener
# already loaded the project, and a hermetic run must not require USER/HOME
# or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/claims.sh
source "$REPO_ROOT/lib/claims.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-claim-proposals}" "$*"
}

# _claim_file ID — absolute path of the claim TOML, via claims.sh's dir.
_claim_file() {
  printf '%s/%s.toml\n' "$(_claims_dir)" "$1"
}

# _mint_proposal_id — echo a fresh id, or nothing when no generator exists.
# Same order as emit_tape_proposal (dev/dev-poll.sh): uuidgen, then the
# kernel uuid.
_mint_proposal_id() {
  local id
  id="$(uuidgen 2>/dev/null)" || id=""
  if [ -z "$id" ]; then
    id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || id=""
  fi
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
  fi
}

# _propose_claim ID — propose one revision, or skip it.
#   0  proposed, or skipped (invalid, already proposed, deleted)
#   1  mint or append failed; no id file written for this revision
_propose_claim() {
  local id="$1"
  local file sha marker class pid payload_hash err payloads_json claims_dir

  file="$(_claim_file "$id")"
  # Deleted between the listing and now: nothing. Retiring a claim is its
  # merge, not a tape record.
  if [ ! -f "$file" ]; then
    return 0
  fi

  err=""
  if ! err="$(claim_valid "$id" 2>&1)"; then
    log "invalid claim ${id}: ${err:-bad field}"
    return 0
  fi

  sha="$(sha256sum "$file" | cut -d' ' -f1)"
  marker="${TAPE_DIR}/claims/${id}.${sha}"
  if [ -e "$marker" ]; then
    return 0
  fi

  class="$(claim_field "$id" class)" || class=""

  pid="$(_mint_proposal_id)"
  if [ -z "$pid" ]; then
    log "WARNING: no uuid generator available — proposal not minted for ${id}"
    return 1
  fi

  # Store the claim text first. A failed store still appends the proposal,
  # but with no 10th argument (the record keeps its pre-#1634 shape).
  # tape_payload's return code is unreliable here: with set -e inactive
  # inside the command substitution, a failed mkdir/cp is swallowed and the
  # hash is still echoed (same note as emit_tape_proposal in dev/dev-poll.sh).
  # Keep the ref only when the content-addressed copy actually landed.
  payload_hash="$(tape_payload "$file" 2>/dev/null)" || payload_hash=""
  if [ -n "$payload_hash" ] && [ -f "${PAYLOAD_DIR}/${payload_hash}" ]; then
    :
  else
    if [ -n "$payload_hash" ]; then
      log "WARNING: failed to store payload for claim ${id} — proposal continues without it"
    fi
    payload_hash=""
  fi

  if [ -n "$payload_hash" ]; then
    payloads_json="$(jq -cn --arg h "$payload_hash" '[$h]')"
    if ! tape_proposal "$pid" claim "$class" "" "" '{}' "" approved \
        "claims/${id}.toml" "$payloads_json"; then
      log "WARNING: tape append failed for claim ${id} — no id file written"
      return 1
    fi
  else
    if ! tape_proposal "$pid" claim "$class" "" "" '{}' "" approved \
        "claims/${id}.toml"; then
      log "WARNING: tape append failed for claim ${id} — no id file written"
      return 1
    fi
  fi

  # Id files only after a successful append, so a failed append never
  # records a proposal that is not on the tape. .current is the revision
  # checks pair with; <id>.<sha> is the "this revision already proposed" mark.
  claims_dir="${TAPE_DIR}/claims"
  if ! mkdir -p "$claims_dir" \
      || ! printf '%s\n' "$pid" > "${claims_dir}/${id}.current" \
      || ! printf '%s\n' "$pid" > "$marker"; then
    rm -f "$marker"
    log "WARNING: failed to record proposal id for claim ${id}"
    return 1
  fi
  return 0
}

failed=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  _propose_claim "$id" || failed=1
done < <(claim_ids)

exit "$failed"
