#!/usr/bin/env bash
# =============================================================================
# tools/rollout.sh — the update-self rollout tool (#2111, #2112, #2113, #2114,
# #2115)
#
# The rollout tool of the update-self rung (docs/design/notes/self-update.md,
# "The flow"): it decides from the canary's evidence lines
# (lib/rollout-evidence.sh, #2106) whether the commit the canary took held,
# failed, or still needs soaking — the "Start", "Watch", "Promote" and
# "Roll back" steps. All rollout logic lives in this one file, which the wall
# protects.
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
#   rollout_rollback_issue COMMIT SUBJECT REASON EVIDENCE
#     File the dev issue for a commit the rollout rolled back from the canary
#     (docs/design/notes/self-update.md, "Roll back"). It files as the
#     caller's forge account: FORGE_TOKEN against FORGE_API, the project
#     repo's API base as lib/env.sh exports it. GET
#     ${FORGE_API}/labels?limit=50 and take the id of `backlog`: a failed
#     GET returns 1, and no such label files the issue without labels. Then
#     POST ${FORGE_API}/issues with title, body and labels, built with jq -n,
#     and print the new issue's .number; return 1 when the POST fails or the
#     answer has no number (#2113). The rollback branch of the tick calls it
#     (#2115); a canary moved off the commit by hand files no issue.
#
#   rollout_tick
#     One supervisor tick (#2114, #2115; the supervisor calls it per tick,
#     #2116). A tick either watches the open rollout — promoting it or rolling
#     it back — or, when none is open, decides whether to start one
#     (docs/design/notes/self-update.md, "Start", "Watch", "Promote",
#     "Roll back" and "Records and the grade"). Steps in order, each ending
#     the tick:
#       1. ${TAPE_DIR}/rollout/HOLD exists        -> "on hold"
#       2. the pack has no soak_s or take_polls   -> "off: no pack"
#       3. the canary's last take/poll line is not ref canary (its jobspec has
#          no FACTORY_REF yet)                    -> "idle: <job> does not follow canary"
#       4. rollout_heads fails                    -> "idle: no live/canary branch"
#       5. live is not on main                    -> "ERROR: live <sha> is not on main"
#       6. a rollout is open (id, commit C): watch C with rollout_watch and
#          log "open: <id>" (#2115):
#            canary != C                         -> rolled back, reason "moved",
#                                                   bit rolled_back 0, no issue
#            verdict wait                        -> a closed run, "watching
#                                                   <sha7>: <polls> polls, <soak_s>s"
#            verdict promote                     -> live to C (on failure: a
#                                                   run with status failed, the
#                                                   rollout stays open); else the
#                                                   outcome (promoted 1, smoke
#                                                   <v.smoke>, numbers soak_s and
#                                                   polls), a closed run, open =
#                                                   null, "promoted <sha7>"
#            verdict rollback                    -> canary forced back to live
#                                                   (on failure: a run with
#                                                   status failed, the rollout
#                                                   stays open); else the outcome
#                                                   (promoted 0, rolled_back 1),
#                                                   a closed run, open = null,
#                                                   blocked_main = main, "rolled
#                                                   back <sha7>: <reason>", and
#                                                   rollout_rollback_issue(C, the
#                                                   commit's subject, the reason,
#                                                   C's last 20 evidence lines);
#                                                   a failed issue logs a WARNING
#       7. canary differs from live               -> force canary back to live,
#                                                   "canary reset to live"
#       8. main equals live                       -> nothing
#       9. main equals blocked_main               -> "waiting for main to move past <sha7>"
#       10. start: canary to main, proposal, state, run -> "started <sha7>"
#     A failed tape append logs a WARNING and changes no decision. After a
#     rollback blocked_main is main's head at that moment: no rollout starts
#     until main moves past it, so the next one takes the fix.
#     Env seams: TAPE_DIR (default /srv/disinto/tape), ROLLOUT_GIT_DIR (default
#     PROJECT_REPO_ROOT), ROLLOUT_CANARY_JOB (default agents-review-qwen),
#     ROLLOUT_PACK_FILE (default ${OPS_REPO_ROOT:-}/packs/rollout.toml),
#     ROLLOUT_NOW (epoch, default now). State lives in
#     ${TAPE_DIR}/rollout/state.json as
#     {"open":null|{"id","commit","moved_at"},"blocked_main":null|"<sha>"};
#     a missing file means both null. Log lines go to stderr as
#     "[<iso>] rollout: <text>", and every path returns 0: the tool fails
#     closed, so a broken tick never aborts the supervisor.
#
# Polls count lines, not minutes: a review poll waits for its reviews, so one
# iteration can outlast POLL_INTERVAL. A canary that writes nothing is waited
# on; the healer's lag notice covers that case (step 14 of the sprint).
#
# Run directly: `tools/rollout.sh tick` runs the tick above; any other
# argument prints the usage and exits 2. Sourcing the file defines the
# functions without running anything.
#
# Tests: tests/acceptance/issue-2111.sh, tests/acceptance/issue-2112.sh,
# tests/acceptance/issue-2113.sh, tests/acceptance/issue-2114.sh,
# tests/acceptance/issue-2115.sh.
# =============================================================================
set -euo pipefail

# The tick writes tape records (#2114), and stats_epoch_to_iso converts the
# tick's epoch clock to the ISO stamps the tape wants: busybox `date` (the CI
# image) cannot parse @epoch.
# shellcheck source=../lib/tape.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/tape.sh"
# shellcheck source=../lib/stats.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/stats.sh"

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

# ── filing the dev issue for a rolled-back commit (#2113) ────────────────────
# "Roll back" of docs/design/notes/self-update.md: the canary failed on the
# commit, the rollout moved canary back to live, and dev gets one issue with
# the commit and the evidence so the fix is the next thing rolled out. The
# issue is filed as the caller's forge account (FORGE_TOKEN from lib/env.sh,
# FORGE_API its API base for the project repo).

rollout_rollback_issue() {
  if [ "$#" -ne 4 ]; then
    echo "usage: rollout_rollback_issue COMMIT SUBJECT REASON EVIDENCE" >&2
    return 2
  fi
  local commit="$1" subject="$2" reason="$3" evidence="$4"

  if ! command -v jq >/dev/null 2>&1; then
    echo "rollout: required tool missing: jq" >&2
    return 1
  fi
  if [ -z "${FORGE_API:-}" ] || [ -z "${FORGE_TOKEN:-}" ]; then
    echo "rollout: rollout_rollback_issue needs FORGE_API and FORGE_TOKEN" >&2
    return 1
  fi

  # The hint for the Problem section, by the rollback reason of rollout_watch.
  local hint
  case "$reason" in
    smoke)
      hint="the smoke (\`.woodpecker/agent-smoke.sh\`) failed on it, see \`smoke_tail\`" ;;
    rc)
      hint="\`review/review-poll.sh\` exited non-zero" ;;
    not-taken)
      hint="the canary did not take it within two polls (\`pull_factory_repo\` in \`docker/agents/entrypoint.sh\`)" ;;
    left)
      hint="the canary stopped running it" ;;
    work)
      hint="every review the canary started on it failed" ;;
    *)
      hint="$reason" ;;
  esac

  # Step 1: the id of the backlog label. A failed GET aborts the filing; a
  # missing label files the issue without labels.
  local labels_json label_id=""
  if ! labels_json="$(curl -sf -H "Authorization: token ${FORGE_TOKEN}" \
      "${FORGE_API}/labels?limit=50" 2>/dev/null)"; then
    return 1
  fi
  if ! label_id="$(printf '%s' "$labels_json" | jq -r \
      '[.[] | select(.name == "backlog")][0].id // empty' 2>/dev/null)"; then
    return 1
  fi

  # Step 2: file the issue.
  local title="fix(rollout): ${commit:0:7} failed on the canary (${reason})"
  local body="## Problem
The canary ran \`${commit}\` (${subject}) and the rollout rolled it back: ${hint}.

Its evidence (newest last):

\`\`\`
${evidence}
\`\`\`

## Proposed solution
Find why the canary failed on this commit and fix it on \`main\`. No rollout starts until \`main\` moves; the next one takes the fix.

## Acceptance criteria
- [ ] .woodpecker/agent-smoke.sh passes on the fix.
- [ ] The failure shown above does not occur with the fix.

## Acceptance test
\`tests/acceptance/issue-<this issue's number>.sh\`"

  local payload created number
  payload="$(jq -n \
    --arg title "$title" \
    --arg body "$body" \
    --argjson labels "[${label_id}]" \
    '{title: $title, body: $body, labels: $labels}')"

  if ! created="$(curl -sf -X POST -H "Authorization: token ${FORGE_TOKEN}" \
      -H "Content-Type: application/json" \
      "${FORGE_API}/issues" -d "$payload" 2>/dev/null)"; then
    return 1
  fi
  number="$(printf '%s' "$created" | jq -r '.number // empty' 2>/dev/null)"
  if [ -z "$number" ]; then
    return 1
  fi
  printf '%s\n' "$number"
}

# ── the tick: start, watch, promote or roll back (#2114, #2115) ───────────────
# The supervisor runs `tools/rollout.sh tick` every tick (#2116). The tick's
# clock and paths are env seams so a test can run it hermetically.

# _rollout_log TEXT — one tick line on stderr: "[<iso>] rollout: <text>".
_rollout_log() {
  printf '[%s] rollout: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# _rollout_pack_int PACK KEY — the integer value of KEY in the flat TOML pack,
# printed on stdout; nothing when the file is unreadable or the key is absent
# or holds a non-integer. Blank lines, inline comments and non-assignments are
# skipped, the rule the repair pack reader uses (lib/repair-suspend.sh).
_rollout_pack_int() {
  local pack="$1" key="$2"
  [ -r "$pack" ] || return 0
  awk -v want="$key" '
    {
      row = $0
      sub(/[[:space:]]*#.*$/, "", row)
      gsub(/^[[:space:]]+/, "", row)
      gsub(/[[:space:]]+$/, "", row)
      if (row == "") next
      eq = index(row, "=")
      if (eq <= 1) next
      name = substr(row, 1, eq - 1)
      value = substr(row, eq + 1)
      gsub(/^[[:space:]]+/, "", name)
      gsub(/[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      if (name == want && value ~ /^-?[0-9]+$/) { print value; exit }
    }
  ' "$pack"
}

# _rollout_state_read FILE — the rollout state as a JSON object; the empty
# object when the file is missing or unreadable.
_rollout_state_read() {
  local file="$1" body
  body=""
  if [ -r "$file" ]; then
    body="$(cat "$file" 2>/dev/null || true)"
  fi
  if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "$body"
  else
    printf '{"open":null,"blocked_main":null}\n'
  fi
}

# _rollout_state_open FILE ID COMMIT MOVED_AT — record the rollout this tick
# started: open = {id, commit, moved_at}, blocked_main = null, every other key
# of the state kept. Written to a temp file in the same directory, then moved.
_rollout_state_open() {
  local file="$1" id="$2" commit="$3" moved="$4" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/state.XXXXXX" 2>/dev/null)" || return 1
  if jq -cn --arg id "$id" --arg commit "$commit" --argjson moved "$moved" \
      --arg current "$(_rollout_state_read "$file")" '
      ((try ($current | fromjson)) // {})
      + {open: {id: $id, commit: $commit, moved_at: $moved}, blocked_main: null}' \
      >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# _rollout_state_close FILE BLOCKED_MAIN — close the rollout this tick decided
# about: open = null, blocked_main = BLOCKED_MAIN (an empty argument keeps the
# current value), every other key of the state kept. Written to a temp file in
# the same directory, then moved.
_rollout_state_close() {
  local file="$1" blocked="${2:-}" dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$(mktemp "$dir/state.XXXXXX" 2>/dev/null)" || return 1
  if jq -cn --arg blocked "$blocked" --arg current "$(_rollout_state_read "$file")" '
      ((try ($current | fromjson)) // {})
      + {open: null}
      + (if $blocked != "" then {blocked_main: $blocked} else {} end)' \
      >"$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

rollout_tick() {
  if ! command -v jq >/dev/null 2>&1; then
    _rollout_log "ERROR: required tool missing: jq"
    return 0
  fi

  local tape_dir="${TAPE_DIR:-/srv/disinto/tape}"
  local dir="${ROLLOUT_GIT_DIR:-${PROJECT_REPO_ROOT:-}}"
  local job="${ROLLOUT_CANARY_JOB:-agents-review-qwen}"
  local pack="${ROLLOUT_PACK_FILE:-${OPS_REPO_ROOT:-}/packs/rollout.toml}"
  local state_file="${tape_dir}/rollout/state.json"
  local now
  if [[ "${ROLLOUT_NOW:-}" =~ ^[0-9]+$ ]]; then
    now="$ROLLOUT_NOW"
  else
    now="$(date -u +%s)"
  fi

  # 1. The owner's hold freezes the rollouts, as for sprints.
  if [ -e "${tape_dir}/rollout/HOLD" ]; then
    _rollout_log "on hold"
    return 0
  fi

  # 2. Without the soak there is no rollout to decide about.
  local soak take_polls
  soak="$(_rollout_pack_int "$pack" soak_s)"
  take_polls="$(_rollout_pack_int "$pack" take_polls)"
  if [ -z "$soak" ] || [ -z "$take_polls" ]; then
    _rollout_log "off: no pack"
    return 0
  fi

  # 3. The canary must actually follow the canary branch: until its jobspec
  #    sets FACTORY_REF its evidence names main, and the tool does nothing.
  local evidence last_ref=""
  evidence="${tape_dir}/rollout/evidence/${job}.jsonl"
  if [ -r "$evidence" ]; then
    last_ref="$(jq -rn -R '
      [inputs | fromjson? | select(.kind == "take" or .kind == "poll")]
      | .[-1] | (.ref // empty)' "$evidence" 2>/dev/null)" || last_ref=""
  fi
  if [ "$last_ref" != "canary" ]; then
    _rollout_log "idle: ${job} does not follow canary"
    return 0
  fi

  # 4. The branches must exist.
  local heads main live canary
  if ! heads="$(rollout_heads "$dir")"; then
    _rollout_log "idle: no live/canary branch"
    return 0
  fi
  read -r main live canary <<<"$heads"

  # 5. A live that is not on main is a broken deployment, not a rollout.
  if ! rollout_on_main "$dir" "$live"; then
    _rollout_log "ERROR: live ${live} is not on main"
    return 0
  fi

  local state
  state="$(_rollout_state_read "$state_file")"

  # 6. One rollout at a time: the open one is watched, promoted or rolled
  #    back (#2115). C is the open commit, ID its proposal.
  local open_id open_commit open_moved
  open_id="$(printf '%s' "$state" | jq -r '.open.id // empty' 2>/dev/null)" || open_id=""
  if [ -n "$open_id" ]; then
    open_commit="$(printf '%s' "$state" | jq -r '.open.commit // empty' 2>/dev/null)" || open_commit=""
    open_moved="$(printf '%s' "$state" | jq -r '.open.moved_at // 0' 2>/dev/null)" || open_moved=0
    _rollout_log "open: ${open_id}"

    local v verdict reason started duration_s
    started="$(stats_epoch_to_iso "$now")"
    duration_s=0
    if ! v="$(rollout_watch "$evidence" "$open_commit" "$open_moved" "$now" "$soak" "$take_polls")"; then
      _rollout_log "ERROR: cannot watch the rollout of ${open_commit}"
      return 0
    fi
    if ! verdict="$(printf '%s' "$v" | jq -r '.verdict // "wait"' 2>/dev/null)"; then
      _rollout_log "ERROR: unreadable watch verdict for ${open_commit}"
      return 0
    fi

    local rolled
    if [ "$canary" != "$open_commit" ]; then
      # Someone moved canary off the open commit: it can no longer soak.
      reason="moved"
      rolled=0
    elif [ "$verdict" = "wait" ]; then
      local polls soak
      polls="$(printf '%s' "$v" | jq -r '.polls // 0' 2>/dev/null)" || polls=0
      soak="$(printf '%s' "$v" | jq -r '.soak_s // 0' 2>/dev/null)" || soak=0
      if ! tape_run "$open_id" supervisor rollout "$started" "$started" '1' \
          "{\"duration_s\":${duration_s}}" completed >/dev/null 2>&1; then
        _rollout_log "WARNING: tape: failed to append the run of ${open_id}"
      fi
      _rollout_log "watching ${open_commit:0:7}: ${polls} polls, ${soak}s"
      return 0
    elif [ "$verdict" = "promote" ]; then
      if ! rollout_move "$dir" live "$open_commit"; then
        _rollout_log "ERROR: cannot move live to ${open_commit}"
        if ! tape_run "$open_id" supervisor rollout "$started" "$started" '1' \
            "{\"duration_s\":${duration_s}}" failed >/dev/null 2>&1; then
          _rollout_log "WARNING: tape: failed to append the run of ${open_id}"
        fi
        return 0
      fi
      if ! tape_outcome "$open_id" \
          "$(printf '%s' "$v" | jq -c '{promoted: 1, rolled_back: 0, smoke: (.smoke // 0)}')" \
          "$(printf '%s' "$v" | jq -c '{soak_s: (.soak_s // 0), polls: (.polls // 0)}')" \
          '{}' '[]' >/dev/null 2>&1; then
        _rollout_log "WARNING: tape: failed to append the outcome of ${open_id}"
      fi
      if ! tape_run "$open_id" supervisor rollout "$started" "$started" '1' \
          "{\"duration_s\":${duration_s}}" completed >/dev/null 2>&1; then
        _rollout_log "WARNING: tape: failed to append the run of ${open_id}"
      fi
      if ! _rollout_state_close "$state_file" ""; then
        _rollout_log "WARNING: failed to write ${state_file}"
      fi
      _rollout_log "promoted ${open_commit:0:7}"
      return 0
    else
      reason="$(printf '%s' "$v" | jq -r '.reason // ""' 2>/dev/null)" || reason=""
      rolled=1
    fi

    # Roll back: the canary failed on the commit, or moved off it by hand
    # (reason "moved": no issue is filed for that).
    if ! rollout_move "$dir" canary "$live" force; then
      _rollout_log "ERROR: cannot roll canary back to ${live}"
      if ! tape_run "$open_id" supervisor rollout "$started" "$started" '1' \
          "{\"duration_s\":${duration_s}}" failed >/dev/null 2>&1; then
        _rollout_log "WARNING: tape: failed to append the run of ${open_id}"
      fi
      return 0
    fi
    if ! tape_outcome "$open_id" \
        "$(printf '%s' "$v" | jq -c --argjson rolled "$rolled" \
            '{promoted: 0, rolled_back: $rolled, smoke: (.smoke // 0)}')" \
        "$(printf '%s' "$v" | jq -c '{soak_s: (.soak_s // 0), polls: (.polls // 0)}')" \
        '{}' '[]' >/dev/null 2>&1; then
      _rollout_log "WARNING: tape: failed to append the outcome of ${open_id}"
    fi
    if ! tape_run "$open_id" supervisor rollout "$started" "$started" '1' \
        "{\"duration_s\":${duration_s}}" completed >/dev/null 2>&1; then
      _rollout_log "WARNING: tape: failed to append the run of ${open_id}"
    fi
    if ! _rollout_state_close "$state_file" "$main"; then
      _rollout_log "WARNING: failed to write ${state_file}"
    fi
    _rollout_log "rolled back ${open_commit:0:7}: ${reason}"

    # One dev issue names the commit and its evidence, so the fix becomes the
    # next rollout. A failed filing is a warning, not a decision.
    if [ "$reason" != "moved" ]; then
      local subject issue_evidence
      subject="$(git -C "$dir" log -1 --format=%s "$open_commit" 2>/dev/null)" || subject=""
      issue_evidence="$(grep -F "$open_commit" "$evidence" 2>/dev/null | tail -20)" || issue_evidence=""
      if ! rollout_rollback_issue "$open_commit" "$subject" "$reason" "$issue_evidence" >/dev/null 2>&1; then
        _rollout_log "WARNING: could not file the dev issue for ${open_commit:0:7}"
      fi
    fi
    return 0
  fi

  # 7. A canary that drifted off live is pulled back before anything starts.
  if [ "$canary" != "$live" ]; then
    if rollout_move "$dir" canary "$live" force; then
      _rollout_log "canary reset to live"
    else
      _rollout_log "WARNING: could not reset canary to ${live}"
    fi
    return 0
  fi

  # 8. Nothing to start: live already runs main's head.
  if [ "$main" = "$live" ]; then
    return 0
  fi

  # 9. A commit the last rollout rolled back: wait for main to move past it.
  local blocked_main=""
  blocked_main="$(printf '%s' "$state" | jq -r '.blocked_main // empty' 2>/dev/null)" || blocked_main=""
  if [ -n "$blocked_main" ] && [ "$blocked_main" = "$main" ]; then
    _rollout_log "waiting for main to move past ${main:0:7}"
    return 0
  fi

  # 10. Start.
  if ! rollout_move "$dir" canary "$main"; then
    _rollout_log "ERROR: cannot move canary to ${main}"
    return 0
  fi

  local id started duration_s
  id="rollout-${now}-${main:0:12}"
  started="$(stats_epoch_to_iso "$now")"
  if ! tape_proposal "$id" rollout "$job" "" "" "{\"live\":\"${live}\"}" "" auto "$main" \
      >/dev/null 2>&1; then
    _rollout_log "WARNING: tape: failed to append proposal ${id}"
  fi
  if ! _rollout_state_open "$state_file" "$id" "$main" "$now"; then
    _rollout_log "WARNING: failed to write ${state_file}"
  fi
  # The run is this tick: it opens and closes at the tick's clock.
  duration_s=0
  if ! tape_run "$id" supervisor rollout "$started" "$started" '1' \
      "{\"duration_s\":${duration_s}}" completed >/dev/null 2>&1; then
    _rollout_log "WARNING: tape: failed to append the run of ${id}"
  fi
  _rollout_log "started ${main:0:7}"
  return 0
}

# Run directly: `tick` runs the tick; anything else is a usage error. Sourcing
# the file defines the functions without running this guard.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  if [ "$#" -eq 1 ] && [ "$1" = "tick" ]; then
    rollout_tick
    exit 0
  fi
  echo "usage: tools/rollout.sh tick" >&2
  exit 2
fi
