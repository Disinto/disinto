#!/usr/bin/env bash
# =============================================================================
# tools/sprint-outcomes.sh — write each due sprint's outcome from its effect
# (#1676), and return an open sprint at once on a design conflict (#1622)
#
# A design conflict means the rest of the sprint is built on the same design.
# Before the soak verdict, this tool walks open sprints (an id file
# ${TAPE_DIR}/sprints/<N> with no <N>.done) and, when any child's last outcome
# (last in tape order) carries a signature listed in
# ${SPRINT_RETURN_SIGNATURES:-design-conflict} (space-separated), the sprint
# is terminal now:
#
#   * tape_outcome "<sprint id>" '{"returned":1}' '<numbers>' '<children>' '[]'.
#     Bits are exactly {returned: 1} — no effect, nothing was measured.
#     numbers and children are the no-probe shape #1676 writes: duration_s
#     (now minus the id file's mtime, clamped at 0) and the JSON from
#     tools/sprint-children.sh. The comment names the first such child's
#     proposal ref (the issue number).
#   * Then list the milestone's open issues, every page (Forgejo's default
#     page is not the full set): forge_api GET
#     "/issues?milestone=<N>&state=open&type=issues&limit=50&page=<P>".
#     Stop on a short page. A failed call, a non-array, or a repeated page
#     leaves <N>.done unwritten so the next run retries.
#     Each issue whose labels include name "backlog" gets one comment, then
#     loses that label (DELETE "/issues/<issue>/labels/<id>", id from the
#     issue's label object):
#     "Sprint returned: #<child issue> reported a design conflict. Re-add backlog when the design is fixed."
#     A retry skips the POST when that exact body is already on the issue,
#     so a delete that fails after the comment still ends with one comment.
#     Issues without backlog (for example in-progress) are not touched.
#   * Touch <N>.done only after the append and the label pass both succeed,
#     so a failed strip is retried next run without a second outcome.
#
# A sprint returned this run is not also scored by the soak path, even when
# the strip failed and .done was left unwritten.
#
# A sprint comes back with its effect once its soak is over (milestone sprint
# block: effect:/expect:/soak:). This tool is that verdict too: it walks the
# due sprints printed by tools/sprint-due.sh (#1675) and, for each one, appends
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
#   SPRINT_RETURN_SIGNATURES
#                  space-separated child-outcome signatures that return an
#                  open sprint at once (default design-conflict, #1622)
#
# Exit codes:
#   0  every open sprint was processed (a return written, a due outcome
#      written, or legitimately skipped — a failed probe, a malformed expect,
#      or an unreadable milestone)
#   1  the due list, a children count, a tape append, or a return's backlog
#      strip could not be produced
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

# _duration_s FILE — seconds since FILE's mtime, clamped at 0. The number
# #1676 records as duration_s (now minus the id file's mtime).
_duration_s() {
  local epoch duration_s
  epoch="$(date -u +%s)"
  duration_s="$(_file_epoch "$1")"
  duration_s=$(( epoch - ${duration_s:-0} ))
  if [ "$duration_s" -lt 0 ]; then
    duration_s=0
  fi
  printf '%s' "$duration_s"
}

# _numbers_json DURATION [VALUE] — the numbers object #1676 writes.
# duration_s always; effect_value only when a probe ran (VALUE set).
_numbers_json() {
  local duration_s="$1" value="${2:-}"
  if [ -n "$value" ]; then
    jq -cn \
      --arg v "$value" \
      --argjson d "$duration_s" \
      '{effect_value: ($v | tonumber), duration_s: $d}'
  else
    jq -cn --argjson d "$duration_s" '{duration_s: $d}'
  fi
}

# _load_children N PID — print nothing; set CHILDREN_JSON to the rollup from
# tools/sprint-children.sh. Returns 1 (CHILDREN_JSON empty) when the count
# cannot be produced. Logs stay on this tool's stdout (not swallowed by a
# command substitution).
_load_children() {
  local n="$1" pid="$2"
  local reason_file reason rc children
  CHILDREN_JSON=""
  reason_file="$(mktemp)"
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
  CHILDREN_JSON="$children"
  return 0
}

# _touch_done N — the no-second-outcome marker. Same warning as #1676.
_touch_done() {
  local done_file="${SPRINTS_DIR}/${1}.done"
  if ! : >"$done_file"; then
    log "WARNING: could not touch ${done_file} — outcome written, .done left for retry"
    return 1
  fi
  return 0
}

# Milestone numbers returned this run (a leading/trailing space keeps the
# membership test from matching a prefix, " 1 " vs " 11 ").
RETURNED_NS=""

# _mark_returned N — this sprint must not also be scored by the soak path.
_mark_returned() {
  RETURNED_NS="${RETURNED_NS} $1"
}

# _is_returned N — true when _mark_returned named N this run.
_is_returned() {
  case " ${RETURNED_NS} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# _build_return_sigs — set RETURN_SIGS_JSON to the signature list
# (${SPRINT_RETURN_SIGNATURES:-design-conflict}, space-separated).
_build_return_sigs() {
  local rest="${SPRINT_RETURN_SIGNATURES:-design-conflict}" tok json='[]'
  while [ -n "$rest" ]; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || break
    tok="${rest%%[[:space:]]*}"
    if [ "$tok" = "$rest" ]; then
      rest=""
    else
      rest="${rest#"$tok"}"
    fi
    [ -n "$tok" ] || continue
    json="$(jq -cn --argjson a "$json" --arg s "$tok" '$a + [$s]')" || return 1
  done
  RETURN_SIGS_JSON="$json"
  return 0
}

# _return_child_issue PID — set RETURN_CHILD to the issue number of the first
# child (proposal order) whose last outcome signature is in RETURN_SIGS_JSON.
# Empty RETURN_CHILD and rc 0: no return. rc 1: the tape could not be read,
# or the matching child has no numeric ref (the comment cannot name it).
_return_child_issue() {
  local pid="$1"
  local tape="${TAPE_DIR}/tape.jsonl"
  local out rc ref
  RETURN_CHILD=""
  if [ ! -f "$tape" ] || [ ! -s "$tape" ]; then
    return 0
  fi
  rc=0
  out="$(jq -r -sR --arg pid "$pid" --argjson sigs "$RETURN_SIGS_JSON" '
    [ split("\n")[] | (try fromjson catch null) | select(type == "object") ] as $rows
    | [ $rows[] | select(.type == "proposal" and .parent == $pid) ] as $children
    | $children
    | map(
        . as $child
        | ($rows | map(select(.type == "outcome" and .proposal_id == $child.id)) | last) as $last
        | select($last != null and (($sigs | index($last.signature // "")) != null))
        | ($child.ref | if type == "string" or type == "number" then tostring else "" end)
      )
    | first // empty
  ' "$tape" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARNING: could not read child outcomes for sprint ${pid}"
    return 1
  fi
  ref="${out//$'\n'/}"
  if [ -z "$ref" ]; then
    return 0
  fi
  if ! [[ "$ref" =~ ^[0-9]+$ ]]; then
    log "WARNING: sprint ${pid}: return signature has no issue number (ref ${ref})"
    return 1
  fi
  RETURN_CHILD="$ref"
  return 0
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
  # jq -e: 0 true, 1 false. Anything else is a read failure.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    return "$rc"
  fi
  return 2
}

# _return_comment_state NUM COMMENT REASON_FILE — print "yes" when NUM already
# carries COMMENT, "no" when it does not. Returns 1 when a comments page
# cannot be read (a repeated full page counts: the caller must not delete).
_return_comment_state() {
  local num="$1" want="$2" reason_file="$3"
  local page=1 body count prev="" hit rc
  while true; do
    rc=0
    body="$(forge_api GET "/issues/${num}/comments?limit=50&page=${page}" 2>"$reason_file")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
      return 1
    fi
    if ! jq -e 'type == "array"' <<<"$body" >/dev/null 2>&1; then
      return 1
    fi
    hit="$(jq -r --arg b "$want" 'if any(.[]; .body == $b) then "yes" else "no" end' <<<"$body")" || return 1
    if [ "$hit" = "yes" ]; then
      printf '%s' yes
      return 0
    fi
    count="$(jq -r 'length' <<<"$body")" || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    # A short page is the end of the list. The comment is not there.
    if [ "$count" -lt 50 ]; then
      printf '%s' no
      return 0
    fi
    if [ -n "$prev" ] && [ "$body" = "$prev" ]; then
      return 1
    fi
    prev="$body"
    page=$((page + 1))
  done
}

# _strip_backlog N CHILD_ISSUE — comment, then take backlog off, every open
# page of the milestone. Issues without backlog are left alone.
#   0  every backlog issue was commented and unlabelled (or there were none)
#   1  a page, a comment read, a comment post, or a delete failed.
#      .done must stay unwritten so the next run can finish the strip.
_strip_backlog() {
  local n="$1" child_issue="$2"
  local reason_file body reason rc comment body_json issue_json num lid
  local page=1 prev="" count present
  reason_file="$(mktemp)"
  comment="Sprint returned: #${child_issue} reported a design conflict. Re-add backlog when the design is fixed."
  body_json="$(jq -nc --arg b "$comment" '{body: $b}')" || {
    rm -f "$reason_file"
    log "WARNING: sprint ${n}: could not build the return comment"
    return 1
  }
  while true; do
    rc=0
    body="$(forge_api GET \
      "/issues?milestone=${n}&state=open&type=issues&limit=50&page=${page}" \
      2>"$reason_file")" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
      reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
      rm -f "$reason_file"
      log "WARNING: sprint ${n}: open issues page ${page} unreadable${reason:+: ${reason}} — .done left unwritten"
      return 1
    fi
    if ! jq -e 'type == "array"' <<<"$body" >/dev/null 2>&1; then
      rm -f "$reason_file"
      log "WARNING: sprint ${n}: open issues page ${page} is not an array — .done left unwritten"
      return 1
    fi
    count="$(jq -r 'length' <<<"$body" 2>/dev/null || true)"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      rm -f "$reason_file"
      log "WARNING: sprint ${n}: open issues page ${page} has no length — .done left unwritten"
      return 1
    fi
    # Nothing left. A short page below is the same stop, after its issues.
    if [ "$count" -eq 0 ]; then
      rm -f "$reason_file"
      return 0
    fi
    # A stub that ignores page and repeats a full page must not loop, and
    # must not be treated as a finished strip.
    if [ -n "$prev" ] && [ "$body" = "$prev" ]; then
      rm -f "$reason_file"
      log "WARNING: sprint ${n}: open issues page ${page} repeated — .done left unwritten"
      return 1
    fi
    prev="$body"
    while IFS= read -r issue_json || [ -n "${issue_json:-}" ]; do
      [ -n "$issue_json" ] || continue
      num="$(jq -r '.number // empty' <<<"$issue_json" 2>/dev/null || true)"
      [[ "$num" =~ ^[0-9]+$ ]] || continue
      # backlog's id comes from the issue object. No backlog name: leave it
      # alone (in-progress, and anything else, is not a queue entry to pull).
      lid="$(jq -r 'first(.labels[]? | select(.name == "backlog") | (.id | tostring)) // empty' \
        <<<"$issue_json" 2>/dev/null || true)"
      [ -n "$lid" ] || continue
      if ! [[ "$lid" =~ ^[0-9]+$ ]]; then
        rm -f "$reason_file"
        log "WARNING: sprint ${n}: issue #${num} has backlog with no numeric id"
        return 1
      fi
      # Comment first. A later delete failure leaves backlog on, so the next
      # run still sees the issue and skips this POST when the body is there.
      rc=0
      present="$(_return_comment_state "$num" "$comment" "$reason_file")" || rc=$?
      if [ "$rc" -ne 0 ]; then
        reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
        rm -f "$reason_file"
        log "WARNING: sprint ${n}: comments for #${num} unreadable${reason:+: ${reason}} — .done left unwritten"
        return 1
      fi
      if [ "$present" != "yes" ]; then
        rc=0
        forge_api POST "/issues/${num}/comments" -d "$body_json" >/dev/null 2>"$reason_file" || rc=$?
        if [ "$rc" -ne 0 ]; then
          reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
          rm -f "$reason_file"
          log "WARNING: sprint ${n}: could not comment on #${num}${reason:+: ${reason}}"
          return 1
        fi
      fi
      rc=0
      forge_api DELETE "/issues/${num}/labels/${lid}" >/dev/null 2>"$reason_file" || rc=$?
      if [ "$rc" -ne 0 ]; then
        reason="$(head -n 1 "$reason_file" 2>/dev/null || true)"
        rm -f "$reason_file"
        log "WARNING: sprint ${n}: could not remove backlog from #${num}${reason:+: ${reason}}"
        return 1
      fi
    done < <(jq -c '.[]' <<<"$body")
    if [ "$count" -lt 50 ]; then
      rm -f "$reason_file"
      return 0
    fi
    page=$((page + 1))
  done
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

# _sprint_return_one N PID CHILD — write the return outcome, strip backlog,
# touch .done. The caller has already marked N returned.
#   0  written (or the outcome was already on the tape) and backlog stripped
#   1  append or strip failed; .done left unwritten so the next run retries
_sprint_return_one() {
  local n="$1" pid="$2" child_issue="$3"
  local id_file duration_s numbers_json bits_json rc has=0

  _tape_has_outcome "$pid" || has=$?
  if [ "$has" -gt 1 ]; then
    log "WARNING: could not read the tape for sprint ${n} — no outcome this run"
    return 1
  fi
  if [ "$has" -eq 1 ]; then
    if ! _load_children "$n" "$pid"; then
      return 1
    fi
    id_file="${SPRINTS_DIR}/${n}"
    duration_s="$(_duration_s "$id_file")"
    numbers_json="$(_numbers_json "$duration_s")" || {
      log "WARNING: could not build numbers for sprint ${n}"
      return 1
    }
    bits_json="$(jq -cn '{returned: 1}')" || {
      log "WARNING: could not build bits for sprint ${n}"
      return 1
    }
    rc=0
    tape_outcome "$pid" "$bits_json" "$numbers_json" "$CHILDREN_JSON" '[]' || rc=$?
    if [ "$rc" -ne 0 ]; then
      log "WARNING: tape outcome append for sprint ${n} failed — .done left unwritten"
      return 1
    fi
  fi

  if ! _strip_backlog "$n" "$child_issue"; then
    return 1
  fi
  if ! _touch_done "$n"; then
    return 1
  fi
  log "sprint ${n}: returned on child #${child_issue}"
  return 0
}

# _return_open_sprints — return every open sprint a child signature names.
# Marks each matched milestone so the soak path does not also score it.
#   0  every match was written, or there was nothing to return
#   1  a match could not be written or its backlog could not be stripped
_return_open_sprints() {
  local f base n pid rc any_failed=0
  local -a ids=()

  if ! _build_return_sigs; then
    log "WARNING: could not read SPRINT_RETURN_SIGNATURES"
    return 1
  fi
  # An empty list returns nothing. The default is design-conflict.
  if [ "$RETURN_SIGS_JSON" = "[]" ]; then
    return 0
  fi
  if [ ! -d "$SPRINTS_DIR" ]; then
    return 0
  fi
  for f in "$SPRINTS_DIR"/*; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^[0-9]+$ ]] || continue
    if [ -e "${SPRINTS_DIR}/${base}.done" ] || [ -L "${SPRINTS_DIR}/${base}.done" ]; then
      continue
    fi
    ids+=("$base")
  done
  [ "${#ids[@]}" -gt 0 ] || return 0

  while IFS= read -r n; do
    [ -n "$n" ] || continue
    pid="$(_read_pid "$n")"
    [ -n "$pid" ] || continue
    rc=0
    _return_child_issue "$pid" || rc=$?
    if [ "$rc" -ne 0 ]; then
      _mark_returned "$n"
      any_failed=1
      continue
    fi
    [ -n "$RETURN_CHILD" ] || continue
    _mark_returned "$n"
    _sprint_return_one "$n" "$pid" "$RETURN_CHILD" || any_failed=1
  done < <(printf '%s\n' "${ids[@]}" | sort -n)
  return "$any_failed"
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
# A design conflict returns the sprint before any soak verdict (#1622). A
# sprint named here is not also scored below, even when .done was not touched.
_return_open_sprints || failed=1
while IFS=$'\t' read -r n pid || [ -n "$n" ]; do
  [ -n "$n" ] || continue
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  pid="${pid:-}"
  [ -n "$pid" ] || continue
  if _is_returned "$n"; then
    continue
  fi
  _sprint_one "$n" "$pid" || failed=1
done < <(TAPE_DIR="$TAPE_DIR" bash "$DUE_TOOL" 2>/dev/null)

exit "$failed"
