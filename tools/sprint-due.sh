#!/usr/bin/env bash
# =============================================================================
# tools/sprint-due.sh — list the sprints whose soak is over (#1675)
#
# A sprint comes back with its effect, measured a soak period after its work
# is done (milestone sprint block: soak:). This tool is the clock: it knows
# when the work is done and when the soak is over. Nothing calls it until
# #1676, which writes the sprint outcome from this list.
#
# For each id file ${TAPE_DIR}/sprints/<N> (N an integer) without a <N>.done
# marker:
#   * Read milestone N with forge_api GET "/milestones/<N>". A failed call,
#     or a body that is not a milestone object: one log line, skip. The
#     .soak file is left as it was.
#   * Work is done when state is closed, or open_issues is 0 and
#     closed_issues is above 0.
#   * Work done and no <N>.soak: write the current epoch to <N>.soak.
#     Work not done: remove <N>.soak and skip.
#   * Due when now >= the epoch in <N>.soak plus sprint_soak_seconds of the
#     description (lib/sprint-block.sh). A soak file that is not an integer
#     epoch is not due (one log line, the file is not rewritten).
#   * For each due sprint print one line:
#       <N><TAB><sprint proposal id from the id file>
#     Nothing else goes to stdout. Logs go to stderr.
#
# Id files are visited in numeric order. A missing sprints dir, or no integer
# id files, prints nothing and exits 0.
#
# Usage:
#   tools/sprint-due.sh
#
# Environment (optional; the test seam):
#   TAPE_DIR   tape directory (default /srv/disinto/tape)
#   FORGE_API  repo API base, used only when forge_api is not already a
#              function or a command (the gardener's child does not inherit
#              the function; hermetic tests stub the command)
#   FORGE_TOKEN token for that fallback
#
# Exit codes:
#   0  the list was printed (including an empty list, and skips)
#   1  jq is missing
#
# Hermetic aside from the forge_api call and the dir it is pointed at. No
# agent, no secrets (AD-006). Does not source lib/env.sh: the gardener
# already loaded the project, and a hermetic run must not require USER/HOME
# or re-read .env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../lib/sprint-block.sh
source "$REPO_ROOT/lib/sprint-block.sh"
# shellcheck source=../lib/forge-api-fallback.sh
source "$REPO_ROOT/lib/forge-api-fallback.sh"

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
SPRINTS_DIR="${TAPE_DIR}/sprints"

command -v jq >/dev/null 2>&1 || {
  echo "sprint-due: required tool missing: jq" >&2
  exit 1
}

# forge_api: a function or command (hermetic test stub) when present; otherwise
# the quiet lib/forge-api-fallback.sh curl fallback from FORGE_API / FORGE_TOKEN.
# The fallback stays quiet: a failed call is one log line from this tool, not two.

# Same shape as lib/env.sh log(), on stderr so stdout stays the due list.
log() {
  printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "${LOG_AGENT:-sprint-due}" "$*" >&2
}

# _due_log_fail N REASON_FILE — one log line for a milestone that could not
# be read. A callee reason, when it left one, is folded into that line so
# stderr still carries a single line from this tool.
_due_log_fail() {
  local n="$1" reason_file="$2" reason=""
  if [ -s "$reason_file" ]; then
    IFS= read -r reason <"$reason_file" || reason=""
  fi
  if [ -n "$reason" ]; then
    log "forge_api GET /milestones/${n} failed: ${reason}"
  else
    log "forge_api GET /milestones/${n} failed"
  fi
}

# _due_parse_milestone BODY — print one compact JSON object
# {state, open_issues, closed_issues, description} or nothing and return 1.
# Counts are integer strings, or "" when the field is absent or not an
# integer. Description is a string ("" when absent).
_due_parse_milestone() {
  local body="$1"
  printf '%s' "$body" | jq -c '
    if type != "object" then
      error("not an object")
    else
      {
        state: (if (.state | type) == "string" then .state else "" end),
        open_issues: (
          if (.open_issues | type) == "number"
             and (.open_issues == (.open_issues | floor))
          then (.open_issues | tostring)
          else ""
          end
        ),
        closed_issues: (
          if (.closed_issues | type) == "number"
             and (.closed_issues == (.closed_issues | floor))
          then (.closed_issues | tostring)
          else ""
          end
        ),
        description: (
          if (.description | type) == "string" then .description else "" end
        )
      }
    end
  '
}

# _sprint_due_one N — apply the soak clock to one id file. Always returns 0;
# a skip is not a tool failure.
_sprint_due_one() {
  local n="$1"
  local id_file soak_file body parsed rc reason_file
  local state open_issues closed_issues description
  local now epoch soak_s pid

  id_file="${SPRINTS_DIR}/${n}"
  soak_file="${SPRINTS_DIR}/${n}.soak"

  # A .done marker means the outcome was already written. No forge call.
  if [ -e "${SPRINTS_DIR}/${n}.done" ] || [ -L "${SPRINTS_DIR}/${n}.done" ]; then
    return 0
  fi

  reason_file="$(mktemp)"
  rc=0
  body="$(forge_api GET "/milestones/${n}" 2>"$reason_file")" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    _due_log_fail "$n" "$reason_file"
    rm -f "$reason_file"
    return 0
  fi

  rc=0
  parsed="$(_due_parse_milestone "$body" 2>/dev/null)" || rc=$?
  rm -f "$reason_file"
  if [ "$rc" -ne 0 ] || [ -z "$parsed" ]; then
    log "forge_api GET /milestones/${n} failed"
    return 0
  fi

  state="$(printf '%s' "$parsed" | jq -r '.state')"
  open_issues="$(printf '%s' "$parsed" | jq -r '.open_issues')"
  closed_issues="$(printf '%s' "$parsed" | jq -r '.closed_issues')"
  description="$(printf '%s' "$parsed" | jq -r '.description')"

  # closed is enough. Otherwise the milestone is drained: nothing open, and
  # at least one issue was closed (an empty milestone is not done).
  if [ "$state" = "closed" ]; then
    :
  elif [[ "$open_issues" =~ ^[0-9]+$ ]] && [[ "$closed_issues" =~ ^[0-9]+$ ]] \
    && [ "$open_issues" -eq 0 ] && [ "$closed_issues" -gt 0 ]; then
    :
  else
    rm -f "$soak_file"
    return 0
  fi

  now="$(date -u +%s)"
  if [ ! -f "$soak_file" ]; then
    printf '%s\n' "$now" >"$soak_file"
    epoch="$now"
  else
    epoch="$(tr -d '[:space:]' <"$soak_file" 2>/dev/null || true)"
  fi
  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    log "sprint ${n}: soak epoch is not an integer"
    return 0
  fi

  soak_s="$(sprint_soak_seconds "$description")"
  if ! [[ "$soak_s" =~ ^[0-9]+$ ]]; then
    soak_s=0
  fi
  if [ "$now" -ge $((epoch + soak_s)) ]; then
    pid=""
    IFS= read -r pid <"$id_file" || pid=""
    printf '%s\t%s\n' "$n" "$pid"
  fi
  return 0
}

if [ ! -d "$SPRINTS_DIR" ]; then
  exit 0
fi

ids=()
for f in "$SPRINTS_DIR"/*; do
  [ -f "$f" ] || continue
  base="${f##*/}"
  if [[ "$base" =~ ^[0-9]+$ ]]; then
    ids+=("$base")
  fi
done

if [ "${#ids[@]}" -eq 0 ]; then
  exit 0
fi

while IFS= read -r n; do
  [ -n "$n" ] || continue
  _sprint_due_one "$n"
done < <(printf '%s\n' "${ids[@]}" | sort -n)
