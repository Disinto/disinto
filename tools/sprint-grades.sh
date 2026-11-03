#!/usr/bin/env bash
# =============================================================================
# tools/sprint-grades.sh — write each scored sprint's grade from the effect
# scale (#2036)
#
# Grades were the owner's alone: tools/grade.sh appends one with
# who = $USER. The owner decided on 2026-11-02 (docs/design/proposal-loop.md
# §3) that code writes the grade at outcome, reading the effect scale, as
# who: effect-scale; the owner may still override. tools/sprint-outcomes.sh
# (#1676) writes bits.effect and stops; this tool turns that outcome into a
# grade.
#
# While ${TAPE_DIR}/sprints/HOLD exists the tool logs one line and exits 0.
# Otherwise it walks the sprint id files ${TAPE_DIR}/sprints/<N> (integer N,
# numeric order), each holding the sprint's proposal id, and for each one:
#
#   * Skip when the tape has no outcome for the id, or already holds a grade
#     for it with who == "effect-scale" — a rerun appends nothing.
#   * description: forge_api GET "/milestones/<N>". Unreadable: one log line,
#     skip.
#   * level: sprint_level (lib/sprint-block.sh, #2029). rc 1 (an unknown
#     level word): log "sprint <N>: unknown level — not graded", skip.
#     effect: sprint_field.
#   * met: bits.effect of the id's last outcome in tape order; 1 or true ->
#     1, else 0.
#   * state: "${SPRINT_HELD_TOOL:-tools/sprint-held.sh}" <id> (#2030) — one
#     of broke, held, none. A failed call: one log line, skip.
#   * The grade: state broke -> -1. Else, effect `none` or missing ->
#     sprint_level_value of the state (no probe: the merges are all that can
#     confirm it). Else met 1 -> sprint_level_value of the level, met 0 ->
#     sprint_level_value of the state.
#   * tape_grade <id> <value> at_outcome effect-scale. A failed append logs a
#     warning and makes the tool exit 1 at the end. Log:
#     "sprint <N>: graded <value> (<level>, met <met>, <state>)".
#
# Usage:
#   tools/sprint-grades.sh
#
# Environment (all optional; the test seam):
#   TAPE_DIR            tape directory (default /srv/disinto/tape)
#   FORGE_API         repo API base, used only when forge_api is not already
#                     a function or a command
#   FORGE_TOKEN       token for that fallback
#   PROJECT_REPO_ROOT   the project repo the held tool reads
#   SPRINT_HELD_REF     the ref the held tool reads (the gardener passes a
#                       freshly fetched origin/main)
#   SPRINT_HELD_TOOL    the held-state reader (default tools/sprint-held.sh)
#
# Exit codes:
#   0  every sprint with an id file was processed (graded or legitimately
#      skipped — no outcome, already graded, unreadable milestone, unknown
#      level, failed held check)
#   1  a grade append failed
#
# Hermetic aside from the tape, the milestone fetch, and the held tool. No
# agent, no secrets (AD-006). Does not source lib/env.sh: the gardener
# already loaded the project, and a hermetic run must not require USER/HOME
# or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/sprint-block.sh
source "$REPO_ROOT/lib/sprint-block.sh"
# shellcheck source=../lib/tape.sh
source "$REPO_ROOT/lib/tape.sh"
# shellcheck source=../lib/forge-api-fallback.sh
source "$REPO_ROOT/lib/forge-api-fallback.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
SPRINTS_DIR="${TAPE_DIR}/sprints"
HELD_TOOL="${SPRINT_HELD_TOOL:-$REPO_ROOT/tools/sprint-held.sh}"

command -v jq >/dev/null 2>&1 || {
  echo "sprint-grades: required tool missing: jq" >&2
  exit 1
}

# Same shape as lib/env.sh log(), without sourcing it (see header).
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-sprint-grades}" "$*"
}

# _read_pid N — print the sprint proposal id from the id file, or nothing.
_read_pid() {
  local pid=""
  IFS= read -r pid <"${SPRINTS_DIR}/${1}" || pid=""
  pid="${pid//$'\r'/}"
  pid="${pid#"${pid%%[![:space:]]*}"}"
  pid="${pid%"${pid##*[![:space:]]}"}"
  printf '%s' "$pid"
}

# _tape_has_outcome PID — 0 when the tape already holds an outcome for PID,
# 1 when it does not, 2 when the tape cannot be read.
_tape_has_outcome() {
  local pid="$1" tape="${TAPE_DIR}/tape.jsonl" rc=0
  if [ ! -f "$tape" ] || [ ! -s "$tape" ]; then
    return 1
  fi
  jq -e -sR --arg pid "$pid" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
    | any(.type == "outcome" and .proposal_id == $pid)
  ' "$tape" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    return "$rc"
  fi
  return 2
}

# _tape_has_scale_grade PID — 0 when the tape already holds an effect-scale
# grade for PID (a rerun must append nothing), 1 when it does not, 2 when the
# tape cannot be read.
_tape_has_scale_grade() {
  local pid="$1" tape="${TAPE_DIR}/tape.jsonl" rc=0
  if [ ! -f "$tape" ] || [ ! -s "$tape" ]; then
    return 1
  fi
  jq -e -sR --arg pid "$pid" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
    | any(.type == "grade" and .proposal_id == $pid and .who == "effect-scale")
  ' "$tape" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    return "$rc"
  fi
  return 2
}

# _last_effect PID — print bits.effect of the id's last outcome in tape
# order as 1 or 0; rc 1 when the tape cannot be read. Torn lines are skipped.
_last_effect() {
  local pid="$1" tape="${TAPE_DIR}/tape.jsonl" out rc met
  rc=0
  out="$(jq -rRs --arg pid "$pid" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ]
    | [ .[] | select(.type == "outcome" and .proposal_id == $pid) ] | last
    | (.bits.effect // 0)' "$tape" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  met=0
  case "$out" in
    1 | true) met=1 ;;
  esac
  printf '%s' "$met"
  return 0
}

# _grade_one N PID — grade one sprint.
#   0  graded, or legitimately skipped (no outcome, already graded,
#      unreadable milestone, unknown level, failed held check)
#   1  the grade append failed
_grade_one() {
  local n="$1" pid="$2"
  local rc body reason_file reason description effect level state value met

  # Idempotence and the no-outcome skip (see the header).
  rc=0
  _tape_has_outcome "$pid" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "sprint ${n}: no outcome on the tape${rc:+ (rc ${rc})} — not graded"
    return 0
  fi
  if _tape_has_scale_grade "$pid"; then
    log "sprint ${n}: already graded by the effect scale — nothing appended"
    return 0
  fi

  rc=0
  reason_file="$(mktemp)"
  body="$(forge_api GET "/milestones/${n}" 2>"$reason_file")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    rm -f "$reason_file"
    log "sprint ${n}: milestone unreadable${reason:+: ${reason}} — no grade this run"
    return 0
  fi
  rm -f "$reason_file"

  description="$(printf '%s' "$body" | jq -r '.description // empty' 2>/dev/null)" || {
    log "sprint ${n}: milestone body has no description field — no grade this run"
    return 0
  }

  rc=0
  level="$(sprint_level "$description")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "sprint ${n}: unknown level — not graded"
    return 0
  fi
  effect="$(sprint_field "$description" effect)" || effect=""
  effect="${effect:-}"

  rc=0
  met="$(_last_effect "$pid")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "sprint ${n}: could not read the tape — no grade this run"
    return 1
  fi

  rc=0
  state="$("$HELD_TOOL" "$pid")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$state" ]; then
    log "sprint ${n}: held-state check failed (rc ${rc}) — not graded"
    return 0
  fi

  # The effect scale (docs/design/proposal-loop.md §3): broke overrides all;
  # with no probe, the merges are all that can confirm; a met probe confirms
  # the level; otherwise the grade is the held level.
  if [ "$state" = "broke" ]; then
    value=-1
  elif [ -z "$effect" ] || [ "$effect" = "none" ]; then
    value="$(sprint_level_value "$state")" || {
      log "sprint ${n}: unknown held state ${state} — not graded"
      return 0
    }
  elif [ "$met" -eq 1 ]; then
    value="$(sprint_level_value "$level")" || {
      log "sprint ${n}: unknown level value ${level} — not graded"
      return 0
    }
  else
    value="$(sprint_level_value "$state")" || {
      log "sprint ${n}: unknown held state ${state} — not graded"
      return 0
    }
  fi

  rc=0
  reason_file="$(mktemp)"
  tape_grade "$pid" "$value" at_outcome effect-scale >/dev/null 2>"$reason_file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
    rm -f "$reason_file"
    log "WARNING: sprint ${n}: grade append failed (rc ${rc})${reason:+: ${reason}}"
    return 1
  fi
  rm -f "$reason_file"
  log "sprint ${n}: graded ${value} (${level}, met ${met}, ${state})"
  return 0
}

# The hold (see the header): nothing is read or written while it exists.
if [ -e "${SPRINTS_DIR}/HOLD" ]; then
  log "on hold (${SPRINTS_DIR}/HOLD exists): no sprint grades this run"
  exit 0
fi

failed=0
ids=()
if [ -d "$SPRINTS_DIR" ]; then
  for f in "$SPRINTS_DIR"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^[0-9]+$ ]] && ids+=("$base")
  done
fi

[ "${#ids[@]}" -gt 0 ] || exit 0

while IFS= read -r n; do
  [ -n "$n" ] || continue
  pid="$(_read_pid "$n")"
  [ -n "$pid" ] || continue
  _grade_one "$n" "$pid" || failed=1
done < <(printf '%s\n' "${ids[@]}" | sort -n)

exit "$failed"
