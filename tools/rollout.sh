#!/usr/bin/env bash
# =============================================================================
# tools/rollout.sh — the update-self rollout tool (#2111, #2112)
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
#   rollout_heads DIR
#     `timeout 60 git -C DIR ls-remote origin refs/heads/<primary>
#     refs/heads/live refs/heads/canary`, where DIR is a clone whose `origin`
#     is the disinto repo and the primary branch is ${PRIMARY_BRANCH:-main}.
#     Print one line "<main> <live> <canary>" of full SHAs and return 0. Print
#     nothing and return 1 when the command fails or any of the three refs is
#     missing (#2112).
#
#   rollout_on_main DIR SHA
#     Fetch origin/<primary> into DIR, then `git -C DIR merge-base --is-ancestor
#     SHA FETCH_HEAD`. Return 0 when SHA is on the primary branch, 1 when it is
#     not or the fetch fails (#2112).
#
#   rollout_move DIR BRANCH SHA [force]
#     Point BRANCH (live or canary) at SHA by pushing. BRANCH must be live or
#     canary, and force is allowed only with canary — anything else returns 2
#     without pushing. Return 1 without pushing when SHA is not on the primary
#     branch, i.e. when rollout_on_main fails: live and canary only ever point
#     at commits of main (docs/design/notes/self-update.md). Otherwise
#     `git -C DIR push --quiet [--force] origin "SHA:refs/heads/BRANCH"` and
#     return git's code. The push uses the clone's credentials (supervisor-bot
#     in the supervisor container); the forge API cannot move a branch, its
#     PATCH only renames (#2112).
#
# Polls count lines, not minutes: a review poll waits for its reviews, so one
# iteration can outlast POLL_INTERVAL. A canary that writes nothing is waited
# on; the healer's lag notice covers that case (step 14 of the sprint).
#
# Run directly the tool prints its usage and exits 2: the `tick` command that
# starts, promotes or rolls back a rollout (#2114, #2115; the supervisor runs
# it per tick, #2116) is added in step 9 of the sprint.
#
# Tests: tests/acceptance/issue-2111.sh, tests/acceptance/issue-2112.sh.
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

# ── moving live and canary by git (#2112) ─────────────────────────────────────
# DIR is a clone whose `origin` is the disinto repo; the push runs with that
# clone's credentials (supervisor-bot in the supervisor container). The forge's
# API cannot move a branch — its PATCH only renames — so the tool pushes.

rollout_heads() {
  if [ "$#" -ne 1 ]; then
    echo "usage: rollout_heads DIR" >&2
    return 2
  fi
  local dir="$1"
  local primary="${PRIMARY_BRANCH:-main}"

  local out
  if ! out="$(timeout 60 git -C "$dir" ls-remote origin \
      "refs/heads/$primary" "refs/heads/live" "refs/heads/canary" 2>/dev/null)"; then
    return 1
  fi

  # ls-remote answers "<sha>TAB<ref>", one ref per line; a ref the origin does
  # not have simply does not appear, which is a missing head.
  local main="" live="" canary="" sha ref
  while IFS=$'\t' read -r sha ref; do
    case "$ref" in
      "refs/heads/$primary") main="$sha" ;;
      "refs/heads/live") live="$sha" ;;
      "refs/heads/canary") canary="$sha" ;;
    esac
  done <<<"$out"

  if [ -z "$main" ] || [ -z "$live" ] || [ -z "$canary" ]; then
    return 1
  fi
  printf '%s %s %s\n' "$main" "$live" "$canary"
}

rollout_on_main() {
  if [ "$#" -ne 2 ]; then
    echo "usage: rollout_on_main DIR SHA" >&2
    return 2
  fi
  local dir="$1" sha="$2"
  local primary="${PRIMARY_BRANCH:-main}"

  if ! timeout 60 git -C "$dir" fetch --quiet origin "$primary" 2>/dev/null; then
    return 1
  fi
  timeout 60 git -C "$dir" merge-base --is-ancestor "$sha" FETCH_HEAD
}

rollout_move() {
  if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: rollout_move DIR BRANCH SHA [force]" >&2
    return 2
  fi
  local dir="$1" branch="$2" sha="$3"
  local force="${4:-}"

  if [ "$branch" != "live" ] && [ "$branch" != "canary" ]; then
    echo "rollout: branch must be live or canary, got $branch" >&2
    return 2
  fi
  if [ -n "$force" ] && [ "$branch" != "canary" ]; then
    echo "rollout: only canary may be moved with force" >&2
    return 2
  fi

  # live and canary only ever point at commits of the primary branch.
  if ! rollout_on_main "$dir" "$sha"; then
    return 1
  fi

  local push_args=(--quiet)
  if [ -n "$force" ]; then
    push_args+=(--force)
  fi
  timeout 60 git -C "$dir" push "${push_args[@]}" origin "$sha:refs/heads/$branch"
}

# Run directly: `tick` arrives with #2114/#2115; until then the tool only
# prints its usage. Sourcing the file defines rollout_watch without running
# this guard.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo "usage: tools/rollout.sh tick" >&2
  exit 2
fi
