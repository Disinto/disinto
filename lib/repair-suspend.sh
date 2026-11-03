#!/usr/bin/env bash
# repair-suspend.sh — the direct-remedy stop rule (#2053)
#
# docs/design/proposal-loop.md §5: a direct fix is suspended once at least
# suspend_at of its last window tried outcomes failed (the remedy acted and
# the condition did not clear) and the last counted outcome failed. While
# suspended it gets one try per trial_days; a cleared try lifts the
# suspension, and the next failure suspends again.
#
# Source from the caller:
#   source "$(dirname "$0")/repair-suspend.sh"
#
# Functions:
#   repair_suspended CLASS
#     Reads the ops pack (flat TOML, integer values) and the tape in one jq
#     pass, prints "<failed> <counted>" on stdout (the failures and the
#     counted outcomes among the CLASS's last window repair outcomes), then:
#       0  suspended: failed >= suspend_at and the last counted outcome failed
#       2  suspended and a trial is due: as 0, plus trial_days is an integer
#          > 0 and the newest CLASS proposal is older than trial_days * 86400 s
#       1  otherwise
#     A missing pack file, or a missing/non-integer window or suspend_at,
#     turns the rule off: no output, return 1. A missing tape: return 1.
#
# Environment:
#   REPAIR_PACK_FILE  path to the ops pack; default
#                     ${OPS_REPO_ROOT:-}/packs/repair.toml (read the way
#                     tools/calibration.sh reads packs/stuck.toml)
#   TAPE_DIR          tape directory (default /srv/disinto/tape)
#   SUPERVISOR_NOW    epoch clock (default: current UTC time)
#
# Return codes: 0 = suspended, 2 = suspended and trial due, 1 = rule off or
# not suspended. Deps: jq, awk, date. Tests: tests/acceptance/issue-2053.sh.
# shellcheck disable=SC2155

repair_suspended() {
  local class="${1:-}"
  [ -n "$class" ] || return 1

  # Pack: env seam first, then the ops repo pack. window and suspend_at must
  # both be integers, or the rule is off.
  local pack="${REPAIR_PACK_FILE:-${OPS_REPO_ROOT:-}/packs/repair.toml}"
  [ -f "$pack" ] || return 1

  local window="" suspend_at="" trial_days="" pair
  while IFS= read -r pair; do
    case "${pair%%=*}" in
      window) window="${pair#*=}" ;;
      suspend_at) suspend_at="${pair#*=}" ;;
      trial_days) trial_days="${pair#*=}" ;;
    esac
  done <<<"$(awk '
    {
      l = $0
      sub(/[[:space:]]*#.*$/, "", l)   # strip inline comment
      sub(/^[[:space:]]+/, "", l)
      sub(/[[:space:]]+$/, "", l)
      if (l == "") next                # blank line
      eq = index(l, "=")
      if (eq <= 1) next                # not an assignment
      key = substr(l, 1, eq - 1)
      val = substr(l, eq + 1)
      sub(/^[[:space:]]+/, "", key)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (val !~ /^-?[0-9]+$/) next    # non-integer value: not an integer key
      if (key == "window") print "window=" val
      else if (key == "suspend_at") print "suspend_at=" val
      else if (key == "trial_days") print "trial_days=" val
    }
  ' "$pack")"
  if [ -z "$window" ] || [ -z "$suspend_at" ]; then
    return 1
  fi

  # Tape: proposals of loop repair and class CLASS, then their outcomes in
  # tape order (proposal_id, or proposal on pre-#1637 rows); torn lines are
  # skipped (try fromjson), never fatal.
  local tape_file="${TAPE_DIR:-/srv/disinto/tape}/tape.jsonl"
  [ -f "$tape_file" ] || return 1

  local clock="${SUPERVISOR_NOW:-}"
  [[ "$clock" =~ ^[0-9]+$ ]] || clock="$(date -u +%s)"

  local stats failed counted last_failed newest
  stats="$(jq -R -s -r --arg class "$class" --argjson window "$window" '
    def failed: (.bits // {}) as $b
      | (($b.acted // 1) == 1) and (($b.cleared // ($b.regression_cleared // 0)) == 0);
    [ split("\n")[] | select(length > 0) | try fromjson ] as $recs
    | [ $recs[] | select(.type == "proposal" and .loop == "repair" and .class == $class) ] as $props
    | [ $props[] | .id ] as $ids
    | [ $recs[] | select(.type == "outcome")
        | ((.proposal_id // .proposal) as $p
          | select($p != null and ($ids | index($p)) != null)) ] as $outs
    | (if ($outs | length) > $window then $outs[($outs | length) - $window:] else $outs end) as $last
    | ($last | map(select(failed)) | length) as $f
    | (($last | length) > 0 and (($last | last) | failed)) as $lf
    | (($props | map(.t) | max) // "") as $newest
    | "\($f) \($last | length) \(if $lf then 1 else 0 end) \($newest)"
  ' "$tape_file")" || return 1

  read -r failed counted last_failed newest <<<"$stats"
  printf '%s %s\n' "$failed" "$counted"

  if [ "$failed" -ge "$suspend_at" ] && [ "$last_failed" = 1 ]; then
    # Trial: once per trial_days while suspended, if the newest proposal of
    # the class is older than the trial horizon.
    if [[ "$trial_days" =~ ^[0-9]+$ ]] && [ "$trial_days" -gt 0 ] && [ -n "$newest" ]; then
      local newest_epoch
      newest_epoch="$(date -u -d "$newest" +%s 2>/dev/null)" \
        || newest_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${newest%Z}" +%s 2>/dev/null)" \
        || newest_epoch=""
      if [ -n "$newest_epoch" ] && [ $(( clock - newest_epoch )) -gt $(( trial_days * 86400 )) ]; then
        return 2
      fi
    fi
    return 0
  fi
  return 1
}
