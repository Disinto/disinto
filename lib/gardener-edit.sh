#!/usr/bin/env bash
# =============================================================================
# lib/gardener-edit.sh — Direct Forgejo API edit primitives for the gardener.
#
# Foundation for the per-task gardener redesign (#869). Replaces the deferred-
# PR pattern from formulas/run-gardener.toml for label/body edits: instead of
# writing pending-actions.json and applying after merge, the per-task gardener
# (gardener/gardener-step.sh, #871) calls these helpers directly and records
# each call to a journal for audit, since direct edits leave no git history.
#
# SOURCEABLE — no top-level statements with side effects. Source from a script:
#   source "$(dirname "$0")/../lib/gardener-edit.sh"
#
# Public surface:
#   gardener_edit_body     <issue_num> <body_file>
#   gardener_add_label     <issue_num> <label_name>   (idempotent)
#   gardener_remove_label  <issue_num> <label_name>   (idempotent)
#   gardener_post_comment  <issue_num> <body_file>
#   gardener_close_issue   <issue_num>
#   gardener_remove_assignee <issue_num>              (idempotent)
#
# Preconditions (callers — usually env.sh has already set them):
#   FORGE_GARDENER_TOKEN — bot token (env.sh defaults this to FORGE_TOKEN)
#   FORGE_API            — repo API base, e.g. https://forge/api/v1/repos/o/r
#   DISINTO_LOG_DIR      — log dir; gardener/edit.log and gardener/journal.jsonl
#                          are written under $DISINTO_LOG_DIR/gardener/
#
# On non-2xx HTTP responses, every public function returns non-zero and appends
# the full response body (with request context) to $DISINTO_LOG_DIR/gardener/
# edit.log. Each call — success, no-op, or failure — is appended as one JSON
# row to $DISINTO_LOG_DIR/gardener/journal.jsonl in the shape:
#   {"ts":"…","fn":"…","issue":"NN","args":{…},"http_code":NNN|"noop"}
#
# Deps: curl, jq. Bash 4.3+ (associative arrays).
# =============================================================================

# Guard against double-source (associative array re-declaration would error).
# shellcheck disable=SC2317  # `return 0` IS reached; it terminates re-source.
if [ "${_GARDENER_EDIT_SH_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null
fi
_GARDENER_EDIT_SH_LOADED=1

# Label ID cache, keyed by label name. Populated lazily by _ge_label_id().
declare -gA _LABEL_ID_CACHE

# ----------------------------------------------------------------------------
# _ge_log_dir — resolve and ensure the gardener log directory; print path.
# ----------------------------------------------------------------------------
_ge_log_dir() {
  local dir="${DISINTO_LOG_DIR:-/tmp}/gardener"
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# ----------------------------------------------------------------------------
# _ge_log — append a free-form line to edit.log (best-effort, never errors).
# ----------------------------------------------------------------------------
_ge_log() {
  local dir; dir="$(_ge_log_dir)"
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '[%s] %s\n' "$ts" "$*" >> "${dir}/edit.log" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# _ge_journal — append one JSON audit row to journal.jsonl.
# Args: fn issue http_code args_json
# http_code may be a numeric string (e.g. "200") or a keyword like "noop".
# ----------------------------------------------------------------------------
_ge_journal() {
  local fn="$1" issue="$2" http_code="$3" args_json="$4"
  local dir; dir="$(_ge_log_dir)"
  local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq -cn \
    --arg ts "$ts" \
    --arg fn "$fn" \
    --arg issue "$issue" \
    --arg http_code "$http_code" \
    --argjson args "$args_json" \
    '{ts:$ts, fn:$fn, issue:$issue, args:$args,
      http_code:($http_code|tonumber? // $http_code)}' \
    >> "${dir}/journal.jsonl" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# _ge_curl — Forgejo API call with HTTP code capture.
# Stdout: HTTP code on the first line, response body on the rest. Caller
# splits on the first newline. We use this shape (instead of a global var)
# because callers invoke us inside command substitution `$(_ge_curl ...)`,
# which runs in a subshell — globals set by the subshell are not visible to
# the parent. Never aborts under set -e.
# Args: METHOD PATH [extra curl args... e.g. --data @file]
# ----------------------------------------------------------------------------
_ge_curl() {
  local method="$1" path="$2"
  shift 2
  local body_tmp http_code
  body_tmp=$(mktemp /tmp/ge-resp-XXXXXX) || return 1
  http_code=$(curl -sS -o "$body_tmp" -w '%{http_code}' \
    -X "$method" \
    -H "Authorization: token ${FORGE_GARDENER_TOKEN:-${FORGE_TOKEN:-}}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    "${FORGE_API}${path}" \
    "$@" 2>>"$(_ge_log_dir)/edit.log") || http_code="000"
  printf '%s\n' "$http_code"
  cat "$body_tmp" 2>/dev/null || true
  rm -f "$body_tmp"
}

# ----------------------------------------------------------------------------
# _ge_split — split _ge_curl output into _GE_HTTP_CODE + _GE_RESP_BODY.
# Use as: _ge_split "$(_ge_curl ...)"
# ----------------------------------------------------------------------------
_ge_split() {
  local out="$1"
  _GE_HTTP_CODE="${out%%$'\n'*}"
  if [[ "$out" == *$'\n'* ]]; then
    _GE_RESP_BODY="${out#*$'\n'}"
  else
    _GE_RESP_BODY=""
  fi
}

# ----------------------------------------------------------------------------
# _ge_is_2xx — return 0 if argument is a 2xx HTTP code, else 1.
# ----------------------------------------------------------------------------
_ge_is_2xx() {
  case "${1:-}" in
    2??) return 0 ;;
    *)   return 1 ;;
  esac
}

# ----------------------------------------------------------------------------
# _ge_label_id — resolve label name → numeric id (cached). Sets _GE_LABEL_ID;
# empty if not found. Caller MUST invoke directly (not via $(…)) so that the
# cache write to _LABEL_ID_CACHE survives in the caller's shell — command
# substitution would put the cache write in a doomed subshell.
# Paginates the repo's labels endpoint until the label is found or pages run
# out. Cache hit avoids the API call entirely on subsequent lookups.
# ----------------------------------------------------------------------------
_ge_label_id() {
  local name="$1"
  _GE_LABEL_ID=""
  if [ -n "${_LABEL_ID_CACHE[$name]:-}" ]; then
    _GE_LABEL_ID="${_LABEL_ID_CACHE[$name]}"
    return 0
  fi
  local id="" page=1 count
  while :; do
    _ge_split "$(_ge_curl GET "/labels?limit=50&page=${page}")"
    if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
      _ge_log "label list failed http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
      break
    fi
    count=$(printf '%s' "$_GE_RESP_BODY" | jq 'length' 2>/dev/null || echo 0)
    [ "${count:-0}" -gt 0 ] || break
    id=$(printf '%s' "$_GE_RESP_BODY" \
      | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' \
      | head -n1)
    [ -n "$id" ] && break
    [ "${count:-0}" -lt 50 ] && break
    page=$((page + 1))
  done
  if [ -n "$id" ]; then
    _LABEL_ID_CACHE[$name]="$id"
    _GE_LABEL_ID="$id"
  fi
}

# ----------------------------------------------------------------------------
# _ge_issue_has_label — return 0 if issue currently carries the named label.
# Returns 2 if the labels GET itself failed (caller should bail).
# ----------------------------------------------------------------------------
_ge_issue_has_label() {
  local issue="$1" name="$2"
  _ge_split "$(_ge_curl GET "/issues/${issue}/labels")"
  _ge_is_2xx "${_GE_HTTP_CODE}" || return 2
  printf '%s' "$_GE_RESP_BODY" \
    | jq -e --arg n "$name" '[.[] | select(.name==$n)] | length > 0' \
      >/dev/null 2>&1
}

# =============================================================================
# Public functions
# =============================================================================

# gardener_edit_body <issue_num> <new_body_file>
# PATCH /repos/.../issues/<n> with body field set to file contents. Body is
# read from a file (not an argument) to avoid shell-quoting hell on multi-line
# / markdown / backtick-heavy issue bodies.
gardener_edit_body() {
  local issue="${1:-}" body_file="${2:-}"
  if [ -z "$issue" ] || [ -z "$body_file" ]; then
    _ge_log "gardener_edit_body: missing args (issue=$issue body_file=$body_file)"
    return 2
  fi
  if [ ! -f "$body_file" ]; then
    _ge_log "gardener_edit_body: body file not found: $body_file"
    return 2
  fi
  local payload_tmp args_json
  payload_tmp=$(mktemp /tmp/ge-patch-XXXXXX.json)
  jq -Rs '{body:.}' < "$body_file" > "$payload_tmp"
  _ge_split "$(_ge_curl PATCH "/issues/${issue}" --data "@${payload_tmp}")"
  rm -f "$payload_tmp"
  args_json=$(jq -cn --arg f "$body_file" '{body_file:$f}')
  _ge_journal "gardener_edit_body" "$issue" "${_GE_HTTP_CODE}" "$args_json"
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_edit_body issue=${issue} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}

# gardener_add_label <issue_num> <label_name>
# Idempotent: no-op (no API write) if label already applied to the issue.
# Caches label-id lookup in _LABEL_ID_CACHE so repeated adds across issues
# only resolve the label once.
gardener_add_label() {
  local issue="${1:-}" name="${2:-}"
  if [ -z "$issue" ] || [ -z "$name" ]; then
    _ge_log "gardener_add_label: missing args (issue=$issue name=$name)"
    return 2
  fi
  local args_json
  args_json=$(jq -cn --arg n "$name" '{label:$n}')

  if _ge_issue_has_label "$issue" "$name"; then
    _ge_journal "gardener_add_label" "$issue" "noop" "$args_json"
    return 0
  fi

  _ge_label_id "$name"
  local id="${_GE_LABEL_ID}"
  if [ -z "$id" ]; then
    _ge_log "gardener_add_label issue=${issue} unknown label=${name}"
    _ge_journal "gardener_add_label" "$issue" "404" "$args_json"
    return 1
  fi

  _ge_split "$(_ge_curl POST "/issues/${issue}/labels" \
    --data "{\"labels\":[${id}]}")"
  _ge_journal "gardener_add_label" "$issue" "${_GE_HTTP_CODE}" "$args_json"
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_add_label issue=${issue} label=${name} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}

# gardener_remove_label <issue_num> <label_name>
# Idempotent: no-op (no API write) if label is not currently applied.
gardener_remove_label() {
  local issue="${1:-}" name="${2:-}"
  if [ -z "$issue" ] || [ -z "$name" ]; then
    _ge_log "gardener_remove_label: missing args (issue=$issue name=$name)"
    return 2
  fi
  local args_json
  args_json=$(jq -cn --arg n "$name" '{label:$n}')

  if ! _ge_issue_has_label "$issue" "$name"; then
    _ge_journal "gardener_remove_label" "$issue" "noop" "$args_json"
    return 0
  fi

  _ge_label_id "$name"
  local id="${_GE_LABEL_ID}"
  if [ -z "$id" ]; then
    _ge_log "gardener_remove_label issue=${issue} unknown label=${name}"
    _ge_journal "gardener_remove_label" "$issue" "404" "$args_json"
    return 1
  fi

  _ge_split "$(_ge_curl DELETE "/issues/${issue}/labels/${id}")"
  _ge_journal "gardener_remove_label" "$issue" "${_GE_HTTP_CODE}" "$args_json"
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_remove_label issue=${issue} label=${name} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}

# gardener_post_comment <issue_num> <body_file>
# POST /repos/.../issues/<n>/comments with body field from file (avoid quoting
# hell, same as gardener_edit_body).
gardener_post_comment() {
  local issue="${1:-}" body_file="${2:-}"
  if [ -z "$issue" ] || [ -z "$body_file" ]; then
    _ge_log "gardener_post_comment: missing args (issue=$issue body_file=$body_file)"
    return 2
  fi
  if [ ! -f "$body_file" ]; then
    _ge_log "gardener_post_comment: body file not found: $body_file"
    return 2
  fi
  local payload_tmp args_json
  payload_tmp=$(mktemp /tmp/ge-comment-XXXXXX.json)
  jq -Rs '{body:.}' < "$body_file" > "$payload_tmp"
  _ge_split "$(_ge_curl POST "/issues/${issue}/comments" --data "@${payload_tmp}")"
  rm -f "$payload_tmp"
  args_json=$(jq -cn --arg f "$body_file" '{body_file:$f}')
  _ge_journal "gardener_post_comment" "$issue" "${_GE_HTTP_CODE}" "$args_json"
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_post_comment issue=${issue} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}

# gardener_close_issue <issue_num>
# PATCH /repos/.../issues/<n> with state:"closed". Journals the action.
gardener_close_issue() {
  local issue="${1:-}"
  if [ -z "$issue" ]; then
    _ge_log "gardener_close_issue: missing args (issue=$issue)"
    return 2
  fi
  _ge_split "$(_ge_curl PATCH "/issues/${issue}" --data '{"state":"closed"}')"
  _ge_journal "gardener_close_issue" "$issue" "${_GE_HTTP_CODE}" '{}'
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_close_issue issue=${issue} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}

# gardener_remove_assignee <issue_num>
# PATCH /repos/.../issues/<n> with assignees:[]. Clears the assignee.
# Idempotent: no-op (no API write) if the issue has no assignee.
gardener_remove_assignee() {
  local issue="${1:-}"
  if [ -z "$issue" ]; then
    _ge_log "gardener_remove_assignee: missing args (issue=$issue)"
    return 2
  fi
  # Check if the issue already has no assignee (idempotent guard).
  local assignee_login
  _ge_split "$(_ge_curl GET "/issues/${issue}")"
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_remove_assignee issue=${issue} GET failed http=${_GE_HTTP_CODE}"
    return 1
  fi
  assignee_login=$(printf '%s' "$_GE_RESP_BODY" | jq -r '.assignee.login // empty' 2>/dev/null)
  if [ -z "$assignee_login" ]; then
    _ge_journal "gardener_remove_assignee" "$issue" "noop" '{}'
    return 0
  fi
  _ge_split "$(_ge_curl PATCH "/issues/${issue}" --data '{"assignees":[]}')"
  _ge_journal "gardener_remove_assignee" "$issue" "${_GE_HTTP_CODE}" '{}'
  if ! _ge_is_2xx "${_GE_HTTP_CODE}"; then
    _ge_log "gardener_remove_assignee issue=${issue} http=${_GE_HTTP_CODE} body=${_GE_RESP_BODY}"
    return 1
  fi
  return 0
}
