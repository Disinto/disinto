#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1672.sh
#
# Issue #1672: when a dependency is closed without its work landing, the dev
# agent refuses with `unmet_dependency` while dev-poll's own dep check finds
# every dependency closed (#1620 → #1622 got picked, refused and re-queued
# every 10 minutes). handle_refusal() must now leave the issue out of the dev
# queue like the other refusals (_dev_refusal_relabel "blocked", never
# issue_release — unmet_dependency is still not a disposition, so no rejected
# bit and no signature), and the posted comment must note that a closed
# dependency may not have landed and ask a human to re-add backlog.
#
# Acceptance (self-contained — no network; handle_refusal is extracted from
# dev/dev-agent.sh with ac_extract_fn, and issue_post_refusal, issue_release
# and _dev_refusal_relabel are stubbed in-process):
#   1. unmet_dependency (with suggestion)  -> exactly one "Unmet dependency"
#      refusal; body holds the pre-#1672 header + blocked_by + suggestion +
#      the new #1672 paragraph; _dev_refusal_relabel called with "blocked";
#      issue_release and issue_close never called; CLAIMED=false.
#   2. unmet_dependency (no suggestion)    -> same assertions, no suggestion
#      line.
#   3. too_large                          -> pre-#1672 behavior preserved:
#      "Too large for single session", pre-#1613 body text, _dev_refusal_relabel
#      with "underspecified", no release/close, CLAIMED=false.
#
# Run via: tools/run-acceptance.sh 1672
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash grep jq awk

TARGET="$REPO_ROOT/dev/dev-agent.sh"
ac_assert_file "$TARGET" "dev/dev-agent.sh must exist"

# ── Fix text must live in the file the extracted code comes from ─────────────
NEW_PARAGRAPH="dev-poll found every dependency closed, so a closed dependency may not have landed. Re-add backlog once it has."
grep -qF "$NEW_PARAGRAPH" "$TARGET" \
  || ac_fail "dev/dev-agent.sh must contain the #1672 refusal paragraph"
grep -qF '_dev_refusal_relabel "$ISSUE" "blocked"' "$TARGET" \
  || ac_fail "dev/dev-agent.sh must relabel unmet_dependency refusals 'blocked'"

# ── Env for the extracted code (mirrors dev-agent.sh globals) ────────────────
# shellcheck disable=SC2034 # consumed by the eval'd handle_refusal
ISSUE=1672
CLAIMED=true

# ── Stubs: record mutating calls, never touch the network ────────────────────
REFUSALS=()
BODIES=()

issue_post_refusal() {
  # $1 issue  $2 emoji  $3 title  $4 body
  REFUSALS+=("$3")
  BODIES+=("$4")
  CALLS+=("issue_post_refusal $1 $3")
}
issue_release() { CALLS+=("issue_release $1"); }
issue_close()   { CALLS+=("issue_close $1"); }
_dev_refusal_relabel() { CALLS+=("_dev_refusal_relabel $1 $2"); }

# ── Extract handle_refusal from dev-agent.sh ─────────────────────────────────
# dev-agent.sh is a top-level executable (sourcing it would run the whole
# agent), so the refusal logic is extracted by header — exactly as
# issue-1613 does. _dev_refusal_relabel is stubbed in-process rather than
# extracted, so assertions key on the call handle_refusal makes, not on label
# ids.
fn_body="$(ac_extract_fn "handle_refusal" "$TARGET")"
[ -n "$fn_body" ] \
  || ac_fail "could not locate handle_refusal() in dev/dev-agent.sh"
eval "$fn_body"

# ── 1. unmet_dependency (with suggestion) → +`blocked`, never release ────────
CALLS=(); REFUSALS=(); BODIES=(); CLAIMED=true
handle_refusal "unmet_dependency" '{"status":"unmet_dependency","blocked_by":"issue 123","suggestion":"124"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "unmet_dependency: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Unmet dependency" ] \
  || ac_fail "unmet_dependency: refusal title expected 'Unmet dependency' got '${REFUSALS[0]}'"
case "${BODIES[0]}" in
  *"$NEW_PARAGRAPH"*) ;;
  *) ac_fail "unmet_dependency: refusal body must hold the #1672 paragraph" ;;
esac
if ! printf '%s' "${BODIES[0]}" | grep -qF '### Blocked by unmet dependency'; then
  ac_fail "unmet_dependency: refusal body must hold the pre-#1672 header"
fi
if ! printf '%s' "${BODIES[0]}" | grep -qF 'issue 123'; then
  ac_fail "unmet_dependency: refusal body must hold the blocked_by message"
fi
if ! printf '%s' "${BODIES[0]}" | grep -qF '**Suggestion:** Work on #124 first.'; then
  ac_fail "unmet_dependency: refusal body must hold the suggestion line"
fi
ac_has_call_matching "_dev_refusal_relabel 1672 blocked" \
  || ac_fail "unmet_dependency must call _dev_refusal_relabel with 'blocked'"
if ac_has_call_matching 'issue_release 1672'; then
  ac_fail "unmet_dependency must never release the issue"
fi
if ac_has_call_matching 'issue_close 1672'; then
  ac_fail "unmet_dependency must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "unmet_dependency must set CLAIMED=false"
ac_log "unmet_dependency (with suggestion): +blocked, new paragraph, no release/close, CLAIMED=false"

# ── 2. unmet_dependency (no suggestion) → same, no suggestion line ───────────
CALLS=(); REFUSALS=(); BODIES=(); CLAIMED=true
handle_refusal "unmet_dependency" '{"status":"unmet_dependency","blocked_by":"issue 300"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "unmet_dependency: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Unmet dependency" ] \
  || ac_fail "unmet_dependency: refusal title expected 'Unmet dependency' got '${REFUSALS[0]}'"
case "${BODIES[0]}" in
  *"$NEW_PARAGRAPH"*) ;;
  *) ac_fail "unmet_dependency (no suggestion): refusal body must hold the #1672 paragraph" ;;
esac
if printf '%s' "${BODIES[0]}" | grep -qF '**Suggestion:**'; then
  ac_fail "unmet_dependency (no suggestion): refusal body must not hold a suggestion line"
fi
ac_has_call_matching "_dev_refusal_relabel 1672 blocked" \
  || ac_fail "unmet_dependency must call _dev_refusal_relabel with 'blocked'"
if ac_has_call_matching 'issue_release 1672'; then
  ac_fail "unmet_dependency must never release the issue"
fi
if ac_has_call_matching 'issue_close 1672'; then
  ac_fail "unmet_dependency must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "unmet_dependency must set CLAIMED=false"
ac_log "unmet_dependency (no suggestion): +blocked, new paragraph, no release/close, CLAIMED=false"

# ── 3. too_large → pre-#1672 behavior preserved ──────────────────────────────
CALLS=(); REFUSALS=(); BODIES=(); CLAIMED=true
handle_refusal "too_large" '{"status":"too_large","reason":"too big for one session"}'
[ "${#REFUSALS[@]}" -eq 1 ] \
  || ac_fail "too_large: expected exactly one refusal, got ${#REFUSALS[@]}"
[ "${REFUSALS[0]}" = "Too large for single session" ] \
  || ac_fail "too_large: refusal title expected 'Too large for single session' got '${REFUSALS[0]}'"
if ! printf '%s' "${BODIES[0]}" | grep -qF "### Why this can't be implemented as-is"; then
  ac_fail "too_large: refusal body must hold the pre-#1613 header"
fi
if ! printf '%s' "${BODIES[0]}" | grep -qF "A maintainer should split this issue or add more detail to the spec."; then
  ac_fail "too_large: refusal body must hold the pre-#1613 next-steps text"
fi
case "${BODIES[0]}" in
  *"$NEW_PARAGRAPH"*) ac_fail "too_large: refusal body must not hold the #1672 paragraph" ;;
  *) ;;
esac
ac_has_call_matching "_dev_refusal_relabel 1672 underspecified" \
  || ac_fail "too_large must relabel with 'underspecified' (pre-#1613)"
if ac_has_call_matching '_dev_refusal_relabel 1672 blocked'; then
  ac_fail "too_large must not relabel with 'blocked'"
fi
if ac_has_call_matching 'issue_release 1672'; then
  ac_fail "too_large must not release the issue"
fi
if ac_has_call_matching 'issue_close 1672'; then
  ac_fail "too_large must not close the issue"
fi
[ "$CLAIMED" = "false" ] \
  || ac_fail "too_large must set CLAIMED=false"
ac_log "too_large: pre-#1672 behavior preserved (+underspecified, no release, CLAIMED=false)"

ac_pass
