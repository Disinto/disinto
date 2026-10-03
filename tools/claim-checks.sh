#!/usr/bin/env bash
# =============================================================================
# tools/claim-checks.sh — run claim checks; one miss contradicts the claim (#1642)
#
# A claim is knowledge only if the factory checks it (proposal-loop design §6).
# Each check is a closed run under the claim's current proposal. One check that
# misses its expect challenges the claim at once; the outcome is written
# immediately. A challenged claim waits for its revision (a new proposal id in
# <id>.current) — this tool does not revise or retire a claim.
#
# For each id that has ${TAPE_DIR}/claims/<id>.current and passes claim_valid
# (lib/claims.sh, #1640):
#   * pid = the content of <id>.current. Skip when the last tape outcome for
#     pid has bits.contradicted 1.
#   * Skip when <id>.checked holds an epoch newer than now minus
#     ${CLAIM_CHECK_INTERVAL_S:-86400}.
#   * Run the check with probe_value "<check>" (lib/probe.sh, #1673). A value
#     came back when it returns 0.
#   * Append a closed run:
#       tape_run "$pid" gardener bash <started> <ended> 1 '{"duration_s":<n>}' <status>
#     status is completed when a value came back, otherwise failed.
#   * Write the current epoch to <id>.checked. With a value, write
#     "<value> <iso time>" to <id>.last.
#   * When a value came back and sprint_expect_met "<value>" "<expect>" returns
#     1: tape_outcome "$pid" '{"contradicted":1,"held":0}' '{"value":<value>}' '{}' '[]'.
#
# A probe failure is a failed run, not a tool failure. A tape append that does
# not land leaves <id>.checked unwritten (the next run retries) and makes this
# tool exit non-zero. The gardener treats that as a warning; it never fails
# the run.
#
# Usage:
#   tools/claim-checks.sh
#
# Environment (all optional; the test seam):
#   CLAIMS_DIR               claim TOML dir (default ${OPS_REPO_ROOT}/claims)
#   OPS_REPO_ROOT            ops clone; probes run as ${OPS_REPO_ROOT}/<check>
#   TAPE_DIR                 tape directory (default /srv/disinto/tape)
#   CLAIM_CHECK_INTERVAL_S   minimum seconds between checks (default 86400)
#   PROBE_TIMEOUT_S          probe wall clock (default 300, lib/probe.sh)
#
# Exit codes:
#   0  every due claim was checked or skipped (invalid, challenged, interval,
#      missing id)
#   1  a run or a contradicted outcome could not be appended, or the check
#      mark could not be written
#
# Hermetic aside from the tape, claim dir, and probe it is pointed at. No
# network, no agent, no secrets (AD-006). Does not source lib/env.sh: the
# gardener already loaded the project, and a hermetic run must not require
# USER/HOME or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/claims.sh
source "$REPO_ROOT/lib/claims.sh"
# shellcheck source=../lib/probe.sh
source "$REPO_ROOT/lib/probe.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-claim-checks}" "$*"
}

# _check_iso — UTC ISO-8601 second stamp, the tape's t / started / ended shape.
_check_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# _claim_current_ids — ids that have ${TAPE_DIR}/claims/<id>.current, sorted.
# The name filter lives in lib/claims.sh (_claim_ids_in) so it is not copied.
_claim_current_ids() {
  _claim_ids_in "${TAPE_DIR}/claims" .current
}

# _claim_challenged PID — rc 0 when the last tape outcome for PID has
# bits.contradicted == 1. No tape, no outcome, or a different bit: rc 1.
# The tape is append-only; "last" is the last outcome line for this pid, not
# an earlier challenge a later outcome replaced. A torn final line is skipped
# (same fromjson? tolerance as tools/calibration.sh) so one bad line cannot
# hide a challenge or invent one.
_claim_challenged() {
  local pid="$1" tape bit
  tape="${TAPE_DIR}/tape.jsonl"
  [ -s "$tape" ] || return 1
  bit="$(jq -sRr --arg pid "$pid" '
    [ split("\n")[]
      | (try fromjson catch null)
      | select(type == "object" and .type == "outcome" and .proposal_id == $pid)
    ]
    | last
    | .bits.contradicted // empty
  ' "$tape" 2>/dev/null)" || bit=""
  [ "$bit" = "1" ]
}

# _claim_within_interval ID — rc 0 when <id>.checked holds an epoch newer than
# now minus CLAIM_CHECK_INTERVAL_S (default 86400). Missing file, or a value
# that is not an integer epoch: rc 1 (due). A non-integer interval falls back
# to the default rather than skipping forever or aborting under set -e.
_claim_within_interval() {
  local id="$1" file checked now interval threshold
  file="${TAPE_DIR}/claims/${id}.checked"
  [ -f "$file" ] || return 1
  checked="$(tr -d '[:space:]' < "$file" 2>/dev/null || true)"
  [[ "$checked" =~ ^[0-9]+$ ]] || return 1
  interval="${CLAIM_CHECK_INTERVAL_S:-86400}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
  now="$(date -u +%s)"
  threshold=$(( now - interval ))
  [ "$checked" -gt "$threshold" ]
}

# _check_claim ID — run one claim's check, or skip it.
#   0  checked, or skipped (invalid, challenged, inside the interval, no pid)
#   1  the run, the contradicted outcome, or the check mark did not land
_check_claim() {
  local id="$1"
  local current pid check expect value prc reason_file reason
  local started started_epoch ended ended_epoch duration_s status cost
  local expect_rc numbers claims_dir epoch invalid_line

  # claim_valid's own line names the field. A skip is not a tool failure:
  # an invalid file is not a check. Wording differs from claim-proposals so
  # the two tools do not share a copied block.
  invalid_line=""
  if ! invalid_line="$(claim_valid "$id" 2>&1)"; then
    log "skipping claim ${id}: ${invalid_line:-bad field}"
    return 0
  fi

  current="${TAPE_DIR}/claims/${id}.current"
  [ -f "$current" ] || return 0
  pid="$(tr -d '[:space:]' < "$current" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    log "WARNING: empty proposal id for claim ${id} — check skipped"
    return 0
  fi

  # A challenged claim waits for its revision: the next proposal id in
  # <id>.current, written by tools/claim-proposals.sh when the file changes.
  if _claim_challenged "$pid"; then
    return 0
  fi
  if _claim_within_interval "$id"; then
    return 0
  fi

  check="$(claim_field "$id" check)" || check=""
  expect="$(claim_field "$id" expect)" || expect=""

  started_epoch="$(date -u +%s)"
  started="$(_check_iso)"
  reason_file="$(mktemp)"
  prc=0
  value="$(probe_value "$check" 2>"$reason_file")" || prc=$?
  ended_epoch="$(date -u +%s)"
  ended="$(_check_iso)"
  duration_s=$(( ended_epoch - started_epoch ))
  if [ "$duration_s" -lt 0 ]; then
    duration_s=0
  fi
  if [ "$prc" -eq 0 ]; then
    status="completed"
  else
    status="failed"
    value=""
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    log "claim ${id}: check failed${reason:+: ${reason}}"
  fi
  rm -f "$reason_file"

  cost="$(jq -cn --argjson d "$duration_s" '{duration_s: $d}')" || {
    log "WARNING: failed to build cost for claim ${id}"
    return 1
  }
  if ! tape_run "$pid" gardener bash "$started" "$ended" 1 "$cost" "$status"; then
    log "WARNING: tape append failed for claim ${id} — check not recorded"
    return 1
  fi

  # A value came back (probe rc 0). sprint_expect_met rc 1 is the miss that
  # challenges the claim at once. rc 0 is met (no outcome). rc 2 is a
  # malformed expect — claim_valid already rejected that shape; do not invent
  # a contradiction from it.
  if [ "$prc" -eq 0 ]; then
    expect_rc=0
    sprint_expect_met "$value" "$expect" || expect_rc=$?
    if [ "$expect_rc" -eq 1 ]; then
      numbers="$(jq -cn --arg v "$value" '{value: ($v | tonumber)}')" || {
        log "WARNING: value for claim ${id} is not a JSON number — outcome not written"
        return 1
      }
      if ! tape_outcome "$pid" '{"contradicted":1,"held":0}' "$numbers" '{}' '[]'; then
        log "WARNING: tape outcome append failed for claim ${id}"
        return 1
      fi
      log "claim ${id}: contradicted (value ${value}, expect ${expect})"
    fi
  fi

  # Marks only after the tape appends landed, so a failed append is retried
  # next run instead of waiting out the interval with no record. .checked is
  # the interval gate; .last is the observed value (only when one came back).
  claims_dir="${TAPE_DIR}/claims"
  epoch="$(date -u +%s)"
  if ! mkdir -p "$claims_dir" \
      || ! printf '%s\n' "$epoch" > "${claims_dir}/${id}.checked"; then
    log "WARNING: failed to record check time for claim ${id}"
    return 1
  fi
  if [ "$prc" -eq 0 ]; then
    if ! printf '%s %s\n' "$value" "$ended" > "${claims_dir}/${id}.last"; then
      rm -f "${claims_dir}/${id}.checked"
      log "WARNING: failed to record last value for claim ${id}"
      return 1
    fi
  fi
}

failed=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  _check_claim "$id" || failed=1
done < <(_claim_current_ids)

exit "$failed"
