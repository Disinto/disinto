#!/usr/bin/env bash
# =============================================================================
# tools/claims-report.sh — catalog table of each claim's status (#1645)
#
# Humans and organs read the catalog, not the tape (proposal-loop design §7).
# This tool prints that table to stdout, one row per id from claim_ids
# (lib/claims.sh, #1640):
#
#   | claim | class | status | checks | last value | resting sprints | statement |
#
#   status     from the last outcome (last tape line, not the latest t) of the
#              proposal in ${TAPE_DIR}/claims/<id>.current:
#                no .current, or an empty id  -> not proposed
#                no outcome                   -> provisional
#                bits.contradicted 1 (or true)-> challenged
#                bits.held 1 (or true)        -> held
#                anything else                -> provisional
#              A last outcome with both bits set is challenged: a challenge
#              hides a hold, never the other way around.
#   checks     number of completed runs under that proposal id (0 when there
#              is no proposal). failed / abandoned / open runs are not checks.
#   last value content of ${TAPE_DIR}/claims/<id>.last, or -
#   resting    milestone:<N> for each open milestone (forge_api GET
#   sprints    "/milestones?state=open") whose description's rests_on
#              (sprint_field) names the id as a comma-separated token.
#              Numeric milestone order, joined with ", ". None -> -.
#              A closed milestone in the payload is ignored. The call is
#              skipped when claim_ids is empty (nothing to rest on).
#   statement  claim_field statement; class is claim_field class. Empty -> -.
#
# A torn tape line is skipped (same fromjson tolerance as tools/calibration.sh).
# It never fails the report. A forge_api failure, or a milestones body that is
# not a JSON array, prints nothing and exits 1 so the gardener does not publish
# a catalog that silently dropped resting sprints.
#
# Usage:
#   tools/claims-report.sh
#
# Environment (all optional; the test seam):
#   CLAIMS_DIR  claim TOML dir (default ${OPS_REPO_ROOT}/claims, lib/claims.sh)
#   TAPE_DIR    tape directory (default /srv/disinto/tape)
#   FORGE_API   repo API base, used only when forge_api is not already a
#               function or a command (the gardener's child does not inherit
#               the function; hermetic tests stub the command)
#   FORGE_TOKEN token for that fallback
#
# Exit codes:
#   0  table printed (header only when there are no claims)
#   1  jq or python3 missing, or open milestones could not be read
#
# Hermetic aside from the forge_api call and the dirs it is pointed at. No
# agent, no secrets (AD-006). Does not source lib/env.sh: the gardener already
# loaded the project, and a hermetic run must not require USER/HOME or re-read
# .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/claims.sh
source "$REPO_ROOT/lib/claims.sh"

command -v jq >/dev/null 2>&1 || { echo "claims-report: required tool missing: jq" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "claims-report: required tool missing: python3" >&2; exit 1; }

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"

# forge_api is a function in the gardener's shell (lib/env.sh) but this tool
# is a subprocess, so the function is not inherited. A hermetic test puts a
# stub command on PATH. Otherwise fall back to the same curl shape as
# lib/env.sh, using the FORGE_API / FORGE_TOKEN the gardener already exported.
# The URL check is the part of validate_url this call needs (http(s), no
# credential injection); sourcing env.sh would re-read .env.
if ! declare -F forge_api >/dev/null 2>&1 && ! command -v forge_api >/dev/null 2>&1; then
  forge_api() {
    local method="$1" path="$2"
    shift 2
    case "${FORGE_API:-}" in
      http://*|https://*) ;;
      *)
        echo "claims-report: FORGE_API unset or invalid" >&2
        return 1
        ;;
    esac
    if [[ "${FORGE_API}" =~ ^https?://[^@]+@ ]]; then
      echo "claims-report: FORGE_API validation failed" >&2
      return 1
    fi
    if [ -z "${FORGE_TOKEN:-}" ]; then
      echo "claims-report: FORGE_TOKEN unset" >&2
      return 1
    fi
    command -v curl >/dev/null 2>&1 || {
      echo "claims-report: required tool missing: curl" >&2
      return 1
    }
    curl -sf -X "$method" \
      -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}${path}" "$@"
  }
fi

# _md_cell TEXT — one markdown table cell. Newlines become spaces, pipes are
# escaped, ends are trimmed. Empty becomes "-".
_md_cell() {
  local s="${1-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  s="${s//|/\\|}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  if [ -z "$s" ]; then
    s="-"
  fi
  printf '%s' "$s"
}

# _claim_named_in_rests_on RESTS ID — rc 0 when ID is a comma-separated token
# of RESTS (sprint_field's rests_on value). Substring is not a name:
# "dev-comes-back-extra" does not name "dev-comes-back".
_claim_named_in_rests_on() {
  local rests="$1" id="$2" part token
  [ -n "$rests" ] || return 1
  rests="${rests},"
  while [ -n "$rests" ]; do
    part="${rests%%,*}"
    rests="${rests#*,}"
    token="${part#"${part%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    if [ "$token" = "$id" ]; then
      return 0
    fi
  done
  return 1
}

# _proposal_facts PID — print "status<TAB>checks" for the proposal.
# status is provisional / held / challenged. checks is the completed-run count.
# No tape: provisional and 0. A jq failure is a tool failure (rc 1).
_proposal_facts() {
  local pid="$1" tape facts rc
  tape="${TAPE_DIR}/tape.jsonl"
  if [ ! -s "$tape" ]; then
    printf 'provisional\t0\n'
    return 0
  fi
  rc=0
  facts="$(jq -sRr --arg pid "$pid" '
    [ split("\n")[]
      | (try fromjson catch null)
      | select(type == "object")
    ] as $rows
    | ($rows
        | map(select(.type == "outcome" and .proposal_id == $pid))
        | last) as $o
    | ($rows
        | map(select(.type == "run" and .proposal_id == $pid and .status == "completed"))
        | length) as $n
    | (if $o == null then "provisional"
       elif ($o.bits.contradicted == 1 or $o.bits.contradicted == true) then "challenged"
       elif ($o.bits.held == 1 or $o.bits.held == true) then "held"
       else "provisional" end) as $st
    | "\($st)\t\($n)"
  ' "$tape" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$facts" ]; then
    echo "claims-report: failed to read tape for proposal ${pid}" >&2
    return 1
  fi
  printf '%s\n' "$facts"
}

# _last_value ID — content of <id>.last, or "-". Trailing newlines are dropped
# by the substitution; internal newlines become spaces in the cell later.
_last_value() {
  local id="$1" file val
  file="${TAPE_DIR}/claims/${id}.last"
  if [ ! -f "$file" ]; then
    printf '%s\n' "-"
    return 0
  fi
  val="$(cat "$file" 2>/dev/null || true)"
  if [ -z "$val" ]; then
    printf '%s\n' "-"
  else
    printf '%s\n' "$val"
  fi
}

# _resting_sprints ID — "milestone:<N>, milestone:<M>" or "-".
# OPEN_MILESTONES is one JSON object per line ({id, description}), open only.
_resting_sprints() {
  local id="$1" row mid desc rests joined=""
  local -a hits=()
  if [ -z "${OPEN_MILESTONES:-}" ]; then
    printf '%s\n' "-"
    return 0
  fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    mid="$(jq -r '.id // empty' <<<"$row" 2>/dev/null)" || mid=""
    [[ "$mid" =~ ^[0-9]+$ ]] || continue
    desc="$(jq -r '.description // ""' <<<"$row" 2>/dev/null)" || desc=""
    rests="$(sprint_field "$desc" rests_on)" || rests=""
    if _claim_named_in_rests_on "$rests" "$id"; then
      hits+=("$mid")
    fi
  done <<<"$OPEN_MILESTONES"
  if [ "${#hits[@]}" -eq 0 ]; then
    printf '%s\n' "-"
    return 0
  fi
  while IFS= read -r mid; do
    [ -n "$mid" ] || continue
    if [ -z "$joined" ]; then
      joined="milestone:${mid}"
    else
      joined="${joined}, milestone:${mid}"
    fi
  done < <(printf '%s\n' "${hits[@]}" | sort -n | uniq)
  printf '%s\n' "$joined"
}

# _load_open_milestones — set OPEN_MILESTONES, or return 1. Prints nothing
# to stdout. The gardener captures stdout as the catalog; errors stay on stderr.
_load_open_milestones() {
  local raw rc=0 lines
  raw="$(forge_api GET "/milestones?state=open")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "claims-report: forge_api GET /milestones?state=open failed (rc=$rc)" >&2
    return 1
  fi
  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "claims-report: milestones response is not a JSON array" >&2
    return 1
  fi
  lines="$(printf '%s' "$raw" | jq -c '
    map(select((.state // "open") == "open"))
    | .[]
    | {id, description}
  ')" || {
    echo "claims-report: failed to read milestones" >&2
    return 1
  }
  OPEN_MILESTONES="$lines"
  return 0
}

ids="$(claim_ids)" || ids=""
# Milestones before any stdout: a forge failure must not emit a partial table
# (the gardener publishes stdout only on rc 0, but a direct caller must not
# mistake a header for a finished catalog).
if [ -n "$ids" ]; then
  if ! _load_open_milestones; then
    exit 1
  fi
fi

printf '%s\n' '| claim | class | status | checks | last value | resting sprints | statement |'
printf '%s\n' '|---|---|---|---|---|---|---|'

if [ -z "$ids" ]; then
  exit 0
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  current="${TAPE_DIR}/claims/${id}.current"
  class="$(claim_field "$id" class)" || class=""
  statement="$(claim_field "$id" statement)" || statement=""
  last="$(_last_value "$id")"
  sprints="$(_resting_sprints "$id")"
  if [ ! -f "$current" ]; then
    status="not proposed"
    checks="0"
  else
    pid="$(tr -d '[:space:]' < "$current" 2>/dev/null || true)"
    if [ -z "$pid" ]; then
      status="not proposed"
      checks="0"
    else
      facts="$(_proposal_facts "$pid")" || exit 1
      status="${facts%%$'\t'*}"
      checks="${facts#*$'\t'}"
    fi
  fi
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(_md_cell "$id")" \
    "$(_md_cell "$class")" \
    "$(_md_cell "$status")" \
    "$(_md_cell "$checks")" \
    "$(_md_cell "$last")" \
    "$(_md_cell "$sprints")" \
    "$(_md_cell "$statement")"
done <<<"$ids"
