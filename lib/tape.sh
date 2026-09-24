#!/usr/bin/env bash
# tape.sh — append-only experience tape for the proposal loop (#1389)
#
# The organs append narrow typed records to a tape;
# calibration reads the tape to report, no organ reads the tape to act.
# One JSON object per line, appended under a single flock. No prose fields —
# text stays in payloads.
#
# Source from the caller:
#   source "$(dirname "$0")/tape.sh"
#
# Storage (both env-overridable, e.g. for tests):
#   $TAPE_DIR    — default /srv/disinto/tape; records in $TAPE_DIR/tape.jsonl
#   $PAYLOAD_DIR — default /srv/disinto/tape/payloads; content-addressed
#                  payloads (under the /srv/disinto/tape host_volume, #1424)
#
# Functions:
#   tape_proposal ID LOOP CLASS PARENT CAUSED_BY CONTEXT_JSON FORECAST_JSON DECISION REF
#     -> {"type":"proposal","t":<iso>,"id","loop","class","parent","caused_by",
#         "context":{...},"forecast":{...},"decision","ref"}
#     PARENT/CAUSED_BY/FORECAST may be empty — the field is then omitted.
#     FORECAST shape when present: {"p_success":f,"est_cost":f,"est_dvision":f}.
#     CONTEXT must be a JSON object; DECISION and REF non-empty strings.
#   tape_run PROPOSAL_ID ORGAN AGENT STARTED ENDED ATTEMPTS COST_JSON STATUS
#     -> {"type":"run","t",...,"attempts":<number>,"cost":{...},"status"}
#     STATUS in completed|failed|abandoned; COST must be a JSON object.
#     ENDED and STATUS are either both set (closed record) or both empty
#     (OPEN record — session start; the fields are omitted from the line and
#     the run is closed by a second tape_run append with the same
#     PROPOSAL_ID and ended+status set — records are immutable).
#   tape_outcome PROPOSAL_ID BITS_JSON NUMBERS_JSON CHILDREN_JSON PAYLOADS_JSON
#     -> {"type":"outcome","t","proposal_id","bits":{...},"numbers":{...},
#         "children":{...},"payloads":[...]}
#     bits/numbers/children are small code-derived JSON objects; payloads is
#     an array of sha256 refs (lowercase 64-hex, produced by tape_payload).
#   tape_grade PROPOSAL_ID VALUE WHEN WHO
#     -> {"type":"grade","t","proposal_id","value":<number|null>,"when","who"}
#     VALUE may be null; WHEN in at_approval|at_outcome.
#     Echoes the appended record on success (like tape_payload's hash).
#   tape_payload FILE
#     Copies FILE to $PAYLOAD_DIR/<sha256> (idempotent), echoes the hash.
#   proposal_elapsed_s ISSUE — echo the wall-clock pick->terminal span in
#     integer seconds, read from /tmp/dev-proposal-started-<project>-<issue>
#     (project = $PROJECT_NAME, or "default"). Returns 0, echoing the span
#     (now - started, clamped >= 0) when the file exists and holds a non-
#     negative integer epoch; returns 1 (no output) when it is missing or
#     the content is not an integer epoch — callers then omit duration_s from
#     the numbers block (omitted, never 0).
#
# Return codes (writers): 0 = appended, 1 = refused (validation),
# 2 = usage error. tape_payload: 0 = stored, 2 = usage error.

set -euo pipefail

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
PAYLOAD_DIR="${PAYLOAD_DIR:-/srv/disinto/tape/payloads}"

# _tape_deps — refuse early when a required tool is missing.
_tape_deps() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v flock >/dev/null 2>&1 || missing="$missing flock"
  if [ -n "$missing" ]; then
    echo "tape: required tools missing:$missing" >&2
    return 1
  fi
  return 0
}

# _tape_now — UTC ISO 8601 second stamp (portable across GNU/busybox date).
_tape_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _tape_append <record_json> — append one record line, serialized under a
# single flock so concurrent writers never interleave.
_tape_append() {
  local record="$1"
  if ! printf '%s\n' "$record" | jq -e . >/dev/null 2>&1; then
    echo "tape: internal: record is not valid JSON" >&2
    return 1
  fi
  mkdir -p "$TAPE_DIR"
  (
    flock -x 9
    printf '%s\n' "$record" >> "${TAPE_DIR}/tape.jsonl"
  ) 9>"${TAPE_DIR}/.tape.lock"
}

tape_proposal() {
  local id="${1:-}" loop="${2:-}" class="${3:-}" parent="${4:-}"
  local caused_by="${5:-}" context_json="${6:-}" forecast_json="${7:-}"
  local decision="${8:-}" ref="${9:-}"

  if [ -z "$id" ] || [ -z "$loop" ] || [ -z "$class" ] || [ -z "$context_json" ] \
    || [ -z "$decision" ] || [ -z "$ref" ]; then
    echo "usage: tape_proposal ID LOOP CLASS PARENT CAUSED_BY CONTEXT_JSON FORECAST_JSON DECISION REF (PARENT/CAUSED_BY/FORECAST may be empty)" >&2
    return 2
  fi
  _tape_deps || return 2

  if ! printf '%s\n' "$context_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "tape_proposal: context must be a JSON object" >&2
    return 1
  fi
  if [ -n "$forecast_json" ]; then
    if ! printf '%s\n' "$forecast_json" | jq -e '
        type == "object"
        and (.p_success | type == "number")
        and (.est_cost | type == "number")
        and (.est_dvision | type == "number")' >/dev/null 2>&1; then
      echo "tape_proposal: forecast must be {\"p_success\":f,\"est_cost\":f,\"est_dvision\":f}" >&2
      return 1
    fi
  fi

  local t record
  t="$(_tape_now)"
  record="$(jq -cn \
    --arg t "$t" --arg id "$id" --arg loop "$loop" --arg class "$class" \
    --arg parent "$parent" --arg caused_by "$caused_by" \
    --arg context "$context_json" --arg forecast "$forecast_json" \
    --arg decision "$decision" --arg ref "$ref" '
    {type: "proposal", t: $t, id: $id, loop: $loop, class: $class}
    + (if $parent != "" then {parent: $parent} else {} end)
    + (if $caused_by != "" then {caused_by: $caused_by} else {} end)
    + {context: ($context | fromjson)}
    + (if $forecast != "" then {forecast: ($forecast | fromjson)} else {} end)
    + {decision: $decision, ref: $ref}')"
  _tape_append "$record"
}

tape_run() {
  local pid="${1:-}" organ="${2:-}" agent="${3:-}" started="${4:-}"
  local ended="${5:-}" attempts="${6:-}" cost_json="${7:-}" status="${8:-}"

  if [ -z "$pid" ] || [ -z "$organ" ] || [ -z "$agent" ] || [ -z "$started" ] \
    || [ -z "$attempts" ] || [ -z "$cost_json" ]; then
    echo "usage: tape_run PROPOSAL_ID ORGAN AGENT STARTED ENDED ATTEMPTS COST_JSON STATUS (ENDED/STATUS both empty = open record)" >&2
    return 2
  fi
  if { [ -z "$ended" ] && [ -n "$status" ]; } || { [ -n "$ended" ] && [ -z "$status" ]; }; then
    echo "tape_run: ENDED and STATUS must be both set (closed) or both empty (open)" >&2
    return 2
  fi
  _tape_deps || return 2

  if [ -n "$status" ]; then
    case "$status" in
      completed|failed|abandoned) ;;
      *)
        echo "tape_run: status must be completed|failed|abandoned (got '$status')" >&2
        return 1
        ;;
    esac
  fi
  if ! printf '%s\n' "$attempts" | jq -e 'type == "number"' >/dev/null 2>&1; then
    echo "tape_run: attempts must be a number" >&2
    return 1
  fi
  if ! printf '%s\n' "$cost_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "tape_run: cost must be a JSON object" >&2
    return 1
  fi

  local t record
  t="$(_tape_now)"
  record="$(jq -cn \
    --arg t "$t" --arg pid "$pid" --arg organ "$organ" --arg agent "$agent" \
    --arg started "$started" --arg ended "$ended" \
    --arg attempts "$attempts" --arg cost "$cost_json" --arg status "$status" '
    {type: "run", t: $t, proposal_id: $pid, organ: $organ, agent: $agent,
     started: $started,
     attempts: ($attempts | fromjson), cost: ($cost | fromjson)}
    + (if $ended != "" then {ended: $ended} else {} end)
    + (if $status != "" then {status: $status} else {} end)')"
  _tape_append "$record"
}

tape_outcome() {
  local pid="${1:-}" bits_json="${2:-}" numbers_json="${3:-}"
  local children_json="${4:-}" payloads_json="${5:-}"

  if [ -z "$pid" ] || [ -z "$bits_json" ] || [ -z "$numbers_json" ] \
    || [ -z "$children_json" ] || [ -z "$payloads_json" ]; then
    echo "usage: tape_outcome PROPOSAL_ID BITS_JSON NUMBERS_JSON CHILDREN_JSON PAYLOADS_JSON" >&2
    return 2
  fi
  _tape_deps || return 2

  local name
  for name in bits numbers children; do
    case "$name" in
      bits) local j="$bits_json" ;;
      numbers) local j="$numbers_json" ;;
      children) local j="$children_json" ;;
    esac
    if ! printf '%s\n' "$j" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "tape_outcome: $name must be a JSON object" >&2
      return 1
    fi
  done
  if ! printf '%s\n' "$payloads_json" | jq -e \
    'type == "array" and (map(type == "string" and test("^[0-9a-f]{64}$")) | all)' \
    >/dev/null 2>&1; then
    echo "tape_outcome: payloads must be an array of sha256 refs (64 lowercase hex)" >&2
    return 1
  fi

  local t record
  t="$(_tape_now)"
  record="$(jq -cn \
    --arg t "$t" --arg pid "$pid" \
    --arg bits "$bits_json" --arg numbers "$numbers_json" \
    --arg children "$children_json" --arg payloads "$payloads_json" '
    {type: "outcome", t: $t, proposal_id: $pid,
     bits: ($bits | fromjson), numbers: ($numbers | fromjson),
     children: ($children | fromjson), payloads: ($payloads | fromjson)}')"
  _tape_append "$record"
}

tape_grade() {
  local pid="${1:-}" value="${2:-}" when="${3:-}" who="${4:-}"

  if [ -z "$pid" ] || [ -z "$value" ] || [ -z "$when" ] || [ -z "$who" ]; then
    echo "usage: tape_grade PROPOSAL_ID VALUE WHEN WHO (VALUE may be null)" >&2
    return 2
  fi
  _tape_deps || return 2

  case "$when" in
    at_approval|at_outcome) ;;
    *)
      echo "tape_grade: when must be at_approval|at_outcome (got '$when')" >&2
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | jq -e '(. == null) or (type == "number")' >/dev/null 2>&1; then
    echo "tape_grade: value must be null or a number" >&2
    return 1
  fi

  local t record
  t="$(_tape_now)"
  record="$(jq -cn \
    --arg t "$t" --arg pid "$pid" --arg value "$value" \
    --arg when "$when" --arg who "$who" '
    {type: "grade", t: $t, proposal_id: $pid, value: ($value | fromjson),
     when: $when, who: $who}')"
  # Guard the echo on the append's status: in a caller's errexit-suppressed
  # context (e.g. `tape_grade ... || exit "$?"`), a failed _tape_append
  # would not stop the function, and a never-appended record would be
  # echoed as if it had been appended.
  _tape_append "$record" || return 1
  echo "$record"
}

tape_payload() {
  local file="${1:-}"

  if [ -z "$file" ]; then
    echo "usage: tape_payload FILE" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "tape_payload: not a regular file: $file" >&2
    return 2
  fi

  local hash
  hash="$(sha256sum "$file" | cut -d' ' -f1)"
  mkdir -p "$PAYLOAD_DIR"
  local dest="${PAYLOAD_DIR}/${hash}"
  if [ ! -e "$dest" ]; then
    cp "$file" "$dest"
  fi
  echo "$hash"
}

# proposal_elapsed_s — wall-clock pick->terminal span in integer seconds
# (#1452). Shared by the dev proposal outcome emitters in
# dev-poll.sh (emit_tape_outcome) and dev-agent.sh (close_dev_tape_outcome).
# Reads /tmp/dev-proposal-started-<project>-<issue>, where <project> is the
# calling process's $PROJECT_NAME (or "default"). Echoes the span (now -
# started, clamped >= 0) and returns 0 when the file exists and holds a non-
# negative integer epoch; returns 1 (no output) otherwise — callers then
# omit duration_s from the numbers block (omitted, never 0).
proposal_elapsed_s() {
  local issue="${1:-}" project started_file started now duration_s
  project="${PROJECT_NAME:-default}"
  if [ -n "$issue" ]; then
    started_file="/tmp/dev-proposal-started-${project}-${issue}"
    if [ -f "$started_file" ]; then
      started="$(cat "$started_file" 2>/dev/null)" || started=""
      if [[ "$started" =~ ^[0-9]+$ ]]; then
        now="$(date -u +%s)"
        duration_s=$(( now - started ))
        if (( duration_s < 0 )); then
          duration_s=0
        fi
        echo "$duration_s"
        return 0
      fi
    fi
  fi
  return 1
}
