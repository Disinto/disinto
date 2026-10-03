#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1613.sh
#
# Issue #1613: the dev agent's refusal prompt only named unmet_dependency,
# too_large and already_done. Two refusal shapes were missing:
#   * needs_ops      — the issue needs access this repo's code change can't
#       provide (a secret, the ops repo, a running host, or a human step).
#   * design_conflict — the issue contradicts the current code or a design
#       document it cites.
#
# Both get a refusal comment (body = reason) plus the `rejected` label with
# backlog + in-progress removed; unknown statuses keep their pre-#1613 no-op
# behaviour.
#
# Acceptance (self-contained — forge_api, issue_post_refusal, issue_release,
# issue_close are stubbed in-process; no network, no live services):
#   1. The agent prompt lists both new refusal JSON shapes
#      {"status":"needs_ops","reason":"what access is missing"} and
#      {"status":"design_conflict","reason":"the contradiction"}.
#   2. The refusal logic lives in handle_refusal STATUS REFUSAL_JSON and the
#      _dev_refusal_relabel(issue, label) helper, extracted from dev-agent.sh.
#   3. needs_ops     -> "Needs ops access",  +`rejected`,  -backlog/in-progress.
#   4. design_conflict -> "Design conflict", +`rejected`,  -backlog/in-progress.
#   5. too_large     -> "Too large for single session", +`underspecified`,
#       -backlog/in-progress (pre-#1613 preserved).
#   6. unmet_dependency -> "Unmet dependency" (+ #1672 "closed dep may not
#       have landed" note) + add `blocked` / drop `backlog`+`in-progress`;
#       no release, no close (#1672).
#   7. already_done -> "Already implemented", close (pre-#1613).
#   8. Unknown status -> no-op: no comment, no label mutation, CLAIMED untouched.
#
# Run via: tools/run-acceptance.sh 1613
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep jq awk

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

# ── Env for the extracted code (mirrors dev-agent.sh globals) ────────────────
ISSUE=1613
CLAIMED=true

# Fake label directory (a bare array, matching what a real
# `forge_api GET "/labels"` returns — see lib/issue-lifecycle.sh _ilc_ensure_label_id):
# rejected=100, backlog=200, in-progress=300, underspecified=400.
LABELS_JSON='[{"id":100,"name":"rejected"},{"id":101,"name":"blocked"},{"id":200,"name":"backlog"},{"id":300,"name":"in-progress"},{"id":400,"name":"underspecified"}]'

# #1672: the exact paragraph the unmet_dependency refusal body must append.
NEW_PARAGRAPH="dev-poll found every dependency closed, so a closed dependency may not have landed. Re-add backlog once it has."

# ── Stubs: serve the label directory, record every mutating call ─────────────
CALLS=()
REFUSALS=(); BODIES=()

issue_post_refusal() {
  # $1 issue  $2 emoji  $3 title  $4 body
  REFUSALS+=("$3")
  BODIES+=("$4")
  # 1613-specific tag: keeps this stub's window distinct from issue-1672.sh's
  # (per-test-isolation convention).
  CALLS+=("issue-1613 post-refusal $ISSUE $3")
}
issue_release() { CALLS+=("issue_release $1"); }
issue_close()   { CALLS+=("issue_close $1"); }

forge_api() {
  local method="$1" path="$2"
  local extra=("$@")
  local data="" i
  case "${method} ${path}" in
    "GET /labels")
      printf '%s\n' "$LABELS_JSON"
      ;;
    "POST /issues/$ISSUE/labels")
      for i in "${!extra[@]}"; do
        [ "${extra[i]}" = "-d" ] && data="${extra[i+1]}"
      done
      CALLS+=("forge POST /issues/$ISSUE/labels ${data}")
      printf 'null\n'
      ;;
    "DELETE /issues/$ISSUE/labels/"*)
      local lid="${path#*/labels/}"
      CALLS+=("forge DELETE /issues/$ISSUE/labels/${lid}")
      printf 'null\n'
      ;;
    *)
      printf 'null\n'
      ;;
  esac
}

# ── Extract handle_refusal + its helper from dev-agent.sh ─────────────────────
# dev-agent.sh is a top-level executable (sourcing it would run the whole
# agent), so the refusal logic is extracted by header — ac_extract_fn() takes
# `name() {` to the next column-0 closing brace — exactly as issue-1130 does
# for dev-poll.sh.
for fn in _dev_refusal_relabel handle_refusal; do
  fn_body="$(ac_extract_fn "$fn" "$TARGET")"
  [ -n "$fn_body" ] \
    || ac_fail "could not locate ${fn}() in dev/dev-agent.sh"
  eval "$fn_body"
done

# ── 1. The agent prompt lists both new refusal JSON shapes ────────────────────
grep -qF 'what access is missing' "$TARGET" \
  || ac_fail "prompt must list the needs_ops JSON reason"
grep -qF '\"status\":\"needs_ops\"' "$TARGET" \
  || ac_fail "prompt must list the needs_ops JSON status shape"
grep -qF 'the contradiction' "$TARGET" \
  || ac_fail "prompt must list the design_conflict JSON reason"
grep -qF '\"status\":\"design_conflict\"' "$TARGET" \
  || ac_fail "prompt must list the design_conflict JSON status shape"
ac_log "prompt lists needs_ops and design_conflict refusal shapes"

# ── 3. needs_ops → "Needs ops access", +`rejected`, −backlog/in-progress ─────
CALLS=(); REFUSALS=(); CLAIMED=true
handle_refusal "needs_ops" '{"status":"needs_ops","reason":"missing Vault token and the ops repo"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "needs_ops: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Needs ops access" ] \
  || ac_fail "needs_ops: refusal title expected 'Needs ops access' got '${REFUSALS[0]}'"
ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[100]}' \
  || ac_fail "needs_ops must add the rejected label (id 100)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/200' \
  || ac_fail "needs_ops must remove the backlog label (id 200)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/300' \
  || ac_fail "needs_ops must remove the in-progress label (id 300)"
if ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[400]}'; then
  ac_fail "needs_ops must not add the underspecified label (id 400)"
fi
if ac_has_call_matching 'issue_release 1613'; then
  ac_fail "needs_ops must not release the issue"
fi
if ac_has_call_matching 'issue_close 1613'; then
  ac_fail "needs_ops must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "needs_ops must set CLAIMED=false"
ac_log "needs_ops: refusal 'Needs ops access', +rejected, -backlog/in-progress, CLAIMED=false"

# ── 4. design_conflict → "Design conflict", +`rejected`, −backlog/in-progress ─
CALLS=(); REFUSALS=(); CLAIMED=true
handle_refusal "design_conflict" '{"status":"design_conflict","reason":"issue wants a synchronous API but the design is event-driven"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "design_conflict: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Design conflict" ] \
  || ac_fail "design_conflict: refusal title expected 'Design conflict' got '${REFUSALS[0]}'"
ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[100]}' \
  || ac_fail "design_conflict must add the rejected label (id 100)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/200' \
  || ac_fail "design_conflict must remove the backlog label (id 200)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/300' \
  || ac_fail "design_conflict must remove the in-progress label (id 300)"
if ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[400]}'; then
  ac_fail "design_conflict must not add the underspecified label (id 400)"
fi
if ac_has_call_matching 'issue_release 1613'; then
  ac_fail "design_conflict must not release the issue"
fi
if ac_has_call_matching 'issue_close 1613'; then
  ac_fail "design_conflict must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "design_conflict must set CLAIMED=false"
ac_log "design_conflict: refusal 'Design conflict', +rejected, -backlog/in-progress, CLAIMED=false"

# ── 5. too_large → pre-#1613: +`underspecified`, −backlog/in-progress ────────
CALLS=(); REFUSALS=(); CLAIMED=true
handle_refusal "too_large" '{"status":"too_large","reason":"too big for one session"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "too_large: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Too large for single session" ] \
  || ac_fail "too_large: refusal title expected 'Too large for single session' got '${REFUSALS[0]}'"
ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[400]}' \
  || ac_fail "too_large must add the underspecified label (id 400)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/200' \
  || ac_fail "too_large must remove the backlog label (id 200)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/300' \
  || ac_fail "too_large must remove the in-progress label (id 300)"
if ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[100]}'; then
  ac_fail "too_large must not add the rejected label (id 100)"
fi
if ac_has_call_matching 'issue_release 1613'; then
  ac_fail "too_large must not release the issue"
fi
if ac_has_call_matching 'issue_close 1613'; then
  ac_fail "too_large must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "too_large must set CLAIMED=false"
ac_log "too_large: pre-#1613 behaviour preserved (+underspecified, -backlog/in-progress)"

# ── 6. unmet_dependency → #1672: blocked (no release, +`blocked`) ────────────
CALLS=(); REFUSALS=(); BODIES=(); CLAIMED=true
handle_refusal "unmet_dependency" '{"status":"unmet_dependency","blocked_by":"issue 123","suggestion":"123"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "case 6: unmet_dependency expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Unmet dependency" ] \
  || ac_fail "case 6: unmet_dependency title expected 'Unmet dependency' got '${REFUSALS[0]}'"
# #1672: body must hold the pre-#1613 header + blocked_by + suggestion +
# the appended "closed dep may not have landed" paragraph.
case "${BODIES[0]}" in
  *"$NEW_PARAGRAPH"*) ;;
  *) ac_fail "case 6: unmet_dependency body must hold the #1672 paragraph" ;;
esac
if ! printf '%s' "${BODIES[0]}" | grep -qF '### Blocked by unmet dependency'; then
  ac_fail "unmet_dependency: refusal body must hold the pre-#1613 header"
fi
if ! printf '%s' "${BODIES[0]}" | grep -qF 'issue 123'; then
  ac_fail "unmet_dependency: refusal body must hold the blocked_by message"
fi
if ! printf '%s' "${BODIES[0]}" | grep -qF '**Suggestion:** Work on #123 first.'; then
  ac_fail "unmet_dependency: refusal body must hold the suggestion line"
fi
# #1672: relabel to `blocked` (id 101) and drop backlog + in-progress, instead
# of releasing the issue (pre-#1613 behavior, now wrong).
ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[101]}' \
  || ac_fail "unmet_dependency must relabel the issue to blocked (id 101)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/200' \
  || ac_fail "unmet_dependency must remove the backlog label (id 200)"
ac_has_call_matching 'forge DELETE /issues/1613/labels/300' \
  || ac_fail "unmet_dependency must remove the in-progress label (id 300)"
if ac_has_call_matching 'forge POST /issues/1613/labels {"labels":[100]}'; then
  ac_fail "unmet_dependency must not add the rejected label (id 100)"
fi
if ac_has_call_matching 'issue_release 1613'; then
  ac_fail "unmet_dependency must not release the issue (#1672: it blocks it)"
fi
if ac_has_call_matching 'issue_close 1613'; then
  ac_fail "unmet_dependency must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "unmet_dependency must set CLAIMED=false"
ac_log "unmet_dependency: #1672 behaviour (+blocked, #1672 paragraph, no release/close)"

# ── 7. already_done → pre-#1613: close (no relabel) ───────────────────────────
CLAIMED=true
CALLS=(); REFUSALS=()
handle_refusal "already_done" '{"status":"already_done","reason":"shipped in v2"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "already_done: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Already implemented" ] \
  || ac_fail "already_done: refusal title expected 'Already implemented' got '${REFUSALS[0]}'"
ac_has_call_matching 'issue_close 1613' \
  || ac_fail "already_done must close the issue"
if ac_has_call_matching 'forge POST /issues/1613/labels'; then
  ac_fail "already_done must not relabel the issue"
fi
if ac_has_call_matching 'forge DELETE /issues/1613/labels/'; then
  ac_fail "already_done must not relabel the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "already_done must set CLAIMED=false"
ac_log "already_done: pre-#1613 behaviour preserved (close, no relabel)"

# ── 8. Unknown status → no-op: no comment, no relabel, CLAIMED untouched ──────
CLAIMED=true
CALLS=(); REFUSALS=()
handle_refusal "bogus" '{"status":"bogus","reason":"no idea"}'
[ "${#REFUSALS[@]}" -eq 0 ] \
  || ac_fail "unknown status: expected no refusal, got ${#REFUSALS[@]}"
[ "${#CALLS[@]}" -eq 0 ] \
  || ac_fail "unknown status: expected no calls, got: ${CALLS[*]}"
[ "$CLAIMED" = "true" ] \
  || ac_fail "unknown status must not touch CLAIMED"
ac_log "unknown status: no-op (no refusal, no relabel, CLAIMED untouched)"

ac_pass