#!/usr/bin/env bash
# =============================================================================
# tools/sprint-outcomes.sh — write each due sprint's outcome from its effect
# (#1676)
#
# A sprint comes back with its effect once its soak is over (milestone sprint
# block: effect:/expect:/soak:). This tool is the verdict: it walks the due
# sprints printed by tools/sprint-due.sh (#1675) and, for each one, appends
# one tape outcome naming how the effect measured up:
#
#   * For each line `<N><TAB><sprint id>` from tools/sprint-due.sh:
#       * description: forge_api GET "/milestones/<N>", field `description`.
#         A failed call (or an empty body) is one log line and the sprint is
#         skipped for this run.
#       * effect and expect: sprint_field (lib/sprint-block.sh, #1629).
#       * children: the JSON printed by tools/sprint-children.sh <sprint id>
#         (#1674) — {"n_children", n_merged, n_rejected, n_failed}.
#       * effect a path: value="$(probe_value "<effect>")" (lib/probe.sh,
#         #1673). A non-zero return: one log line, no outcome this run. Then
#         sprint_expect_met "<value>" "<expect>": rc 0 -> met 1, rc 1 -> met 0,
#         rc 2 -> one log line, no outcome.
#       * effect `none` or missing: met 1 when n_failed is 0, else 0.
#       * tape_outcome "<sprint id>" '{"effect":<met>,"returned":0}'
#         '<numbers>' '<children>' '[]'. numbers: effect_value when a probe ran,
#         and duration_s = now minus the mtime of the id file.
#       * Touch ${TAPE_DIR}/sprints/<N>.done only after the append succeeds.
#
# The gardener calls this right after refresh_ops_calibration
# (gardener/gardener-run.sh); a non-zero exit only logs a warning.
#
# Usage:
#   tools/sprint-outcomes.sh
#
# Environment (all optional; the test seam):
#   TAPE_DIR        tape directory (default /srv/disinto/tape)
#   OPS_REPO_ROOT   ops clone; probes run as ${OPS_REPO_ROOT}/<effect>
#   FORGE_API       repo API base, used only when forge_api is not already a
#                   function or a command
#   FORGE_TOKEN     token for that fallback
#   PROBE_TIMEOUT_S probe wall clock (default 300, lib/probe.sh)
#
# Exit codes:
#   0  every due sprint was processed (an outcome written, or legitimately
#      skipped — a failed probe, a malformed expect, or an unreadable milestone)
#   1  the due list, a children count, or a tape append could not be produced
#
# Hermetic aside from the tape, the two tools it drives, and the probe it is
# pointed at. No agent, no secrets (AD-006). Does not source lib/env.sh: the
# gardener already loaded the project, and a hermetic run must not require
# USER/HOME or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/sprint-block.sh
source "$REPO_ROOT/lib/sprint-block.sh"
# shellcheck source=../lib/probe.sh
source "$REPO_ROOT/lib/probe.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"
# shellcheck source=../lib/forge-api-fallback.sh
source "$REPO_ROOT/lib/forge-api-fallback.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
SPRINTS_DIR="${TAPE_DIR}/sprints"
DUE_TOOL="$REPO_ROOT/tools/sprint-due.sh"
CHILD_TOOL="$REPO_ROOT/tools/sprint-children.sh"

command -v jq >/dev/null 2>&1 || {
  echo "sprint-outcomes: required tool missing: jq" >&2
  exit 1
}

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-sprint-outcomes}" "$*"
}

# forge_api: a function or command (hermetic test stub) when present; otherwise
# the quiet lib/forge-api-fallback.sh curl fallback from FORGE_API / FORGE_TOKEN.
# The fallback stays quiet: a failed call is one log line from this tool, not two.

# _file_epoch FILE — FILE's mtime in integer seconds (0 when missing/unreadable).
_file_epoch() {
  local file="$1" m
  m="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s' "$m"
}

# _sprint_one N PID — write the outcome for one due sprint.
#   0  written, or legitimately skipped (unreadable milestone, failed probe,
#      malformed expect — retried next run, .done untouched)
#   1  a children count or tape append failed (the tool cannot complete this
#      sprint)
_sprint_one() {
  local n="$1" pid="$2"
  local id_file body reason_file reason rc
  local description effect expect
  local children n_failed
  local value probe_rc expect_rc met numbers_json duration_s epoch
  local done_file

  id_file="${SPRINTS_DIR}/${n}"
  done_file="${SPRINTS_DIR}/${n}.done"
  reason_file="$(mktemp)"

  # The milestone was already read when sprint-due.sh ruled this sprint due;
  # re-read it here for the description (sprint-due.sh only reports the due
  # line). A transient failure leaves no outcome — the next run retries.
  rc=0
  body="$(forge_api GET "/milestones/${n}" 2>"$reason_file")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    rm -f "$reason_file"
    log "sprint ${n}: milestone unreadable${reason:+: ${reason}} — no outcome this run"
    return 0
  fi
  rm -f "$reason_file"

  description="$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)" || {
    log "sprint ${n}: milestone body has no description field — no outcome this run"
    return 0
  }

  effect="$(sprint_field "$description" effect)" || effect=""
  effect="${effect:-}"
  expect="$(sprint_field "$description" expect)" || expect=""
  expect="${expect:-}"

  # Children rollup from the tape (code-derived counts, never scores, #1674).
  rc=0
  children="$(TAPE_DIR="$TAPE_DIR" bash "$CHILD_TOOL" "$pid" 2>"$reason_file")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$children" ]; then
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    rm -f "$reason_file"
    log "WARNING: children count for sprint ${n} failed${reason:+: ${reason}}"
    return 1
  fi
  rm -f "$reason_file"
  if ! printf '%s\n' "$children" | jq -e 'type == "object"
        and (.n_failed | type == "number")' >/dev/null 2>&1; then
    log "WARNING: children JSON for sprint ${n} is not a count object: ${children}"
    return 1
  fi
  n_failed="$(jq -r '.n_failed // 0' <<<"$children" 2>/dev/null)" || n_failed=0
  [[ "$n_failed" =~ ^[0-9]+$ ]] || n_failed=0

  met=
  numbers_json=""
  if [[ "$effect" != "none" && -n "$effect" ]]; then
    # A probe path. The probe's own reason line goes to stderr; this tool's
    # one log line goes here (stdout).
    probe_rc=0
    value="$(probe_value "$effect" 2>"$reason_file")" || probe_rc=$?
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    rm -f "$reason_file"
    if [ "$probe_rc" -ne 0 ]; then
      log "sprint ${n}: effect ${effect} probe failed${reason:+: ${reason}} — no outcome this run"
      return 0
    fi
    expect_rc=0
    sprint_expect_met "$value" "$expect" || expect_rc=$?
    case "$expect_rc" in
      0) met=1 ;;
      1) met=0 ;;
      *)
        log "sprint ${n}: malformed expect for effect ${effect} — no outcome this run"
        return 0
        ;;
    esac
    epoch="$(date -u +%s)"
    duration_s="$( _file_epoch "$id_file" )"
    duration_s=$(( epoch - ${duration_s:-0} ))
    [[ "$duration_s" -lt 0 ]] && duration_s=0
    numbers_json="$(jq -cn \
      --arg v "$value" \
      --argjson d "$duration_s" \
      '{effect_value: ($v | tonumber), duration_s: $d}')" || {
      log "WARNING: could not build numbers for sprint ${n} (value ${value})"
      return 1
    }
  else
    # effect none or missing: the effect is "did it work" = no child failed.
    met=0
    [[ "$n_failed" -eq 0 ]] && met=1
    epoch="$(date -u +%s)"
    duration_s="$( _file_epoch "$id_file" )"
    duration_s=$(( epoch - ${duration_s:-0} ))
    [[ "$duration_s" -lt 0 ]] && duration_s=0
    numbers_json="$(jq -cn \
      --argjson d "$duration_s" \
      '{duration_s: $d}')" || {
      log "WARNING: could not build numbers for sprint ${n}"
      return 1
    }
  fi

  bits_json="$(jq -cn --argjson m "$met" '{effect: $m, returned: 0}')" || {
    log "WARNING: could not build bits for sprint ${n} (met ${met})"
    return 1
  }

  rc=0
  tape_outcome "$pid" "$bits_json" "$numbers_json" "$children" '[]' || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARNING: tape outcome append for sprint ${n} failed — .done left unwritten"
    return 1
  fi

  # The .done marker is the no-second-outcome guarantee; touch it only once
  # the append landed so a failed write is retried next run.
  if ! : > "$done_file"; then
    log "WARNING: could not touch ${done_file} — outcome written, .done left for retry"
    return 1
  fi
  log "sprint ${n}: outcome written (effect ${met}, ${children})"
  return 0
}

failed=0
while IFS=$'\t' read -r n pid || [ -n "$n" ]; do
  [ -n "$n" ] || continue
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  pid="${pid:-}"
  [ -n "$pid" ] || continue
  _sprint_one "$n" "$pid" || failed=1
done < <(TAPE_DIR="$TAPE_DIR" bash "$DUE_TOOL" 2>/dev/null)

exit "$failed"
