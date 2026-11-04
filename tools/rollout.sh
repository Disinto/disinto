#!/usr/bin/env bash
# =============================================================================
# tools/rollout.sh — the update-self rollout tool (#2111)
#
# The rollout tool of the update-self rung (docs/design/notes/self-update.md,
# "The flow"): it decides from the canary's evidence lines
# (lib/rollout-evidence.sh, #2106) whether the commit the canary took held,
# failed, or still needs soaking — the "Watch", "Promote" and "Roll back"
# steps. All rollout logic lives in this one file, which the wall protects.
#
# functions so far:
#   rollout_watch FILE COMMIT SINCE NOW SOAK_S TAKE_POLLS
#     Read the evidence lines in FILE (one JSON object per line, the shape
#     lib/rollout-evidence.sh writes; a missing FILE has no lines) and print
#     one JSON verdict object for the rollout of COMMIT taken after SINCE:
#       {"verdict":"promote"|"wait"|"rollback",
#        "reason":<"" unless rollback>,
#        "smoke":<1 when the take's smoke is 0, else 0>,
#        "polls":<count of the commit's polls>,
#        "soak_s":<NOW - the take's t, or 0 when there is no take>}
#     Lines with t < SINCE are ignored. Of the rest: take is the first "take"
#     line for COMMIT; polls are the "poll" lines for COMMIT; others are the
#     "poll" lines for another commit before the take's t (all of them when
#     there is no take); work is the "work" lines for COMMIT. Rules, first
#     match wins:
#       1. a take whose smoke is not 0            -> rollback, smoke
#       2. a poll with rc not 0                   -> rollback, rc
#       3. no take and others >= TAKE_POLLS       -> rollback, not-taken
#       4. a take and the last poll line after it (largest t) naming another
#          commit                                -> rollback, left
#       5. no take, or NOW - take.t < SOAK_S, or no polls -> wait
#       6. work lines with total due above 0 and total done 0 -> rollback, work
#       7. otherwise                              -> promote
#     Returns 0 whenever it prints a verdict; usage errors return 2.
#
# Polls count lines, not minutes: a review poll waits for its reviews, so one
# iteration can outlast POLL_INTERVAL. A canary that writes nothing is waited
# on; the healer's lag notice covers that case (step 14 of the sprint).
#
# Run directly the tool prints its usage and exits 2: the `tick` command that
# starts, promotes or rolls back a rollout (#2114, #2115; the supervisor runs
# it per tick, #2116) is added in step 9 of the sprint.
#
# Tests: tests/acceptance/issue-2111.sh.
# =============================================================================
set -euo pipefail

rollout_watch() {
  if [ "$#" -ne 6 ]; then
    echo "usage: rollout_watch FILE COMMIT SINCE NOW SOAK_S TAKE_POLLS" >&2
    return 2
  fi
  local file="$1" commit="$2" since="$3" now="$4" soak="$5" take_polls="$6"

  if ! command -v jq >/dev/null 2>&1; then
    echo "rollout: required tool missing: jq" >&2
    return 1
  fi

  # One jq program over the evidence: a missing or unreadable FILE feeds no
  # lines, so the verdict is wait.
  {
    if [ -r "$file" ]; then
      cat "$file"
    fi
  } | jq -cn -R \
    --argjson since "$since" \
    --argjson now "$now" \
    --argjson soak "$soak" \
    --argjson take_polls "$take_polls" \
    --arg commit "$commit" \
    '
      [inputs | fromjson? | select(.t >= $since)] as $lines
      | ($lines | map(select(.kind == "take" and .commit == $commit))[0]) as $take
      | ($lines | map(select(.kind == "poll" and .commit == $commit))) as $polls
      | ($lines | map(select(.kind == "poll" and .commit != $commit))
             | (if $take then map(select(.t < $take.t)) else . end)) as $others
      | ($lines | map(select(.kind == "work" and .commit == $commit))) as $work
      | (if $take
           then ($lines | map(select(.kind == "poll" and .t > $take.t)) | max_by(.t))
           else null
         end) as $last_poll
      | (
          if $take != null and ($take.smoke // 0) != 0
            then {verdict: "rollback", reason: "smoke"}
          elif ($polls | any(.rc != 0))
            then {verdict: "rollback", reason: "rc"}
          elif ($take == null and ($others | length) >= $take_polls)
            then {verdict: "rollback", reason: "not-taken"}
          elif ($take != null and $last_poll != null and $last_poll.commit != $commit)
            then {verdict: "rollback", reason: "left"}
          elif ($take == null or ($now - $take.t) < $soak or ($polls | length) == 0)
            then {verdict: "wait", reason: ""}
          elif (($work | map(.due) | add // 0) > 0 and ($work | map(.done) | add // 0) == 0)
            then {verdict: "rollback", reason: "work"}
          else
            {verdict: "promote", reason: ""}
          end
        ) + {
          smoke: (if $take != null and ($take.smoke // 0) == 0 then 1 else 0 end),
          polls: ($polls | length),
          soak_s: (if $take != null then ($now - $take.t) else 0 end)
        }
    '
}

# Run directly: `tick` arrives with #2114/#2115; until then the tool only
# prints its usage. Sourcing the file defines rollout_watch without running
# this guard.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo "usage: tools/rollout.sh tick" >&2
  exit 2
fi
