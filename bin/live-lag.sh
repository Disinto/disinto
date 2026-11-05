#!/usr/bin/env bash
# =============================================================================
# live-lag.sh — one owner notice when `live` has stopped catching up (#2119)
#
# The canary rollout (docs/design/notes/self-update.md) fails closed: if
# tools/rollout.sh breaks, `canary` never moves, `live` never fast-forwards,
# every agent keeps the last good version, and nobody notices. No check inside
# the tool can see its own silence, so this one sits outside it. It runs from
# the healer, which runs from /opt/disinto, not from `live`, so it still runs
# when the rollout tool is the broken thing.
#
# bin/healer.sh calls this once per tick, before the notices drain, so the
# notice it queues goes out in the same tick (bin/notices-drain.sh, #2032).
# AD-006: lib/notice.sh only writes a file; the healer is the sender.
#
# Contract:
#   Heads:  timeout 20 git -C ${FACTORY_ROOT:-/opt/disinto} ls-remote origin
#           refs/heads/main refs/heads/live
#           A failure, or no `live` head, means rollouts are not set up: exit 0
#           with the state file untouched.
#   Hours:  the integer lag_notice_h from ${ROLLOUT_PACK_FILE:-
#           /srv/disinto/ops-repo/packs/rollout.toml} (flat TOML); a missing
#           file or key means 24.
#   State:  ${HEALER_STATE_DIR:-/srv/disinto/healer}/live-lag.json holding
#           {"live":"<sha>","since":<epoch>|null,"told":0|1}, written to a temp
#           file in the same directory and then mv'd, so a half-written state
#           is never read.
#   Rules:
#     * live == main: nothing is lagging: state {live, since null, told 0}.
#     * live differs from main and since is null, or the stored live differs
#       from the current live: a promotion restarted the clock, so since = now
#       and told = 0.
#     * live differs, now - since > hours*3600 and told is 0: exactly one
#       notice_owner message. A successful send sets told 1; a failed send
#       leaves told 0 so the next tick tries again.
#     * anything else: state unchanged.
#   Every path exits 0: a git failure, a missing pack, a broken state file or a
#   failed notice must never stop the healer's tick.
#
# Environment seams:
#   FACTORY_ROOT       clone whose `origin` is the factory repo (default
#                      /opt/disinto)
#   ROLLOUT_PACK_FILE  the ops pack that carries lag_notice_h (tools/rollout.sh
#                      reads the same pack for soak_s)
#   HEALER_STATE_DIR   where live-lag.json lives (bin/healer.sh sets it)
#   HEALER_NOW         epoch clock (tests); unset uses date
#   NOTICES_DIR        the notice queue, per lib/notice.sh
#
# Does not source lib/env.sh: this is host-side, like bin/healer.sh and
# bin/notify-owner.sh, and env.sh requires USER/HOME.
#
# Tests: tests/acceptance/issue-2119.sh.
# =============================================================================
set -euo pipefail
# An inherited bash -x would put every command string, token included, on
# stderr: this script is run inside the healer's tick.
set +x

# shellcheck source=../lib/notice.sh
source "$(dirname "$0")/../lib/notice.sh"

DEFAULT_LAG_HOURS=24

# pack_int PACK KEY — the integer value of KEY in a flat TOML pack, printed on
# stdout; nothing when the file is unreadable, the key is absent, or its value
# is not an integer. The rule is the rollout pack reader's; the shape here is
# its own so the two do not share a copy-pasted block (#1134).
pack_int() {
  local file="$1" want="$2"
  [ -r "$file" ] || return 0
  awk -v key="$want" '
    {
      line = $0
      sub(/#.*/, "", line)              # drop the inline comment
      gsub(/^[ \t]+|[ \t]+$/, "", line) # trim both ends
      split(line, kv, "=")
      gsub(/^[ \t]+|[ \t]+$/, "", kv[1])
      if (kv[1] != key) next
      gsub(/^[ \t]+|[ \t]+$/, "", kv[2])
      if (kv[2] ~ /^[0-9]+$/) print kv[2]
    }
  ' "$file"
}

# iso_utc EPOCH — the epoch as YYYY-MM-DDTHH:MM:SSZ, or the epoch itself when
# `date` cannot parse it.
iso_utc() {
  local epoch="$1"
  date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s\n' "$epoch"
}

# read_heads ROOT — "MAIN LIVE" on stdout, empty when git failed or a head is
# missing. ls-remote answers "<sha>TAB<ref>", one ref per line; a ref the
# origin does not have simply does not appear.
read_heads() {
  local root="$1" out sha ref main="" live=""
  if ! out="$(timeout 20 git -C "$root" ls-remote origin \
      refs/heads/main refs/heads/live 2>/dev/null)"; then
    return 1
  fi
  while IFS=$'\t' read -r sha ref; do
    case "$ref" in
      refs/heads/main) main="$sha" ;;
      refs/heads/live) live="$sha" ;;
    esac
  done <<<"$out"
  [ -n "$main" ] && [ -n "$live" ] || return 1
  printf '%s %s\n' "$main" "$live"
}

# write_state STATE_FILE LIVE SINCE TOLD — atomically write the state. SINCE is
# the empty string for null. Returns 1 when the directory or the write fails;
# the caller keeps the tick going either way.
write_state() {
  local file="$1" live="$2" since="$3" told="$4" dir tmp json
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  if command -v jq >/dev/null 2>&1; then
    json="$(jq -c --arg live "$live" --arg since "$since" --argjson told "$told" '
      {live: $live,
       since: (if $since == "" then null else ($since | tonumber) end),
       told: $told}' 2>/dev/null)" || json=""
  else
    json=""
  fi
  [ -n "$json" ] || json="{\"live\":\"${live}\",\"since\":${since:-null},\"told\":${told}}"
  tmp="$dir/.live-lag-$$.tmp"
  if ! printf '%s\n' "$json" 2>/dev/null >"$tmp"; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! mv "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

main() {
  local root state_file pack hours now heads main_sha live_sha
  local stored_live since told

  root="${FACTORY_ROOT:-/opt/disinto}"
  state_file="${HEALER_STATE_DIR:-/srv/disinto/healer}/live-lag.json"

  # 1. The heads. No `live` (or no git, or a dead origin): rollouts are not
  #    set up here, so there is nothing to lag and nothing to record.
  if ! heads="$(read_heads "$root")"; then
    exit 0
  fi
  read -r main_sha live_sha <<<"$heads"

  # 2. The hours, from the ops pack the rollout tool reads.
  pack="${ROLLOUT_PACK_FILE:-/srv/disinto/ops-repo/packs/rollout.toml}"
  hours="$(pack_int "$pack" lag_notice_h)"
  case "$hours" in
    ''|*[!0-9]*) hours="$DEFAULT_LAG_HOURS" ;;
  esac

  # 3. The clock.
  now="${HEALER_NOW:-$(date +%s)}"
  case "$now" in
    ''|*[!0-9]*) now="$(date +%s)" ;;
  esac

  # 4. The stored state. An unreadable or malformed file reads as "nothing
  #    recorded yet": the clock simply restarts.
  stored_live="" since="" told=0
  if [ -r "$state_file" ]; then
    stored_live="$(jq -r '.live // empty' "$state_file" 2>/dev/null || true)"
    since="$(jq -r 'if .since == null then empty else (.since | tostring) end' \
      "$state_file" 2>/dev/null || true)"
    told="$(jq -r '.told // 0' "$state_file" 2>/dev/null || true)"
  fi
  case "$since" in
    ''|*[!0-9]*) since="" ;;
  esac
  case "$told" in
    ''|*[!0-9]*) told=0 ;;
  esac

  # 5. live caught up: the wait is over, the clock is off.
  if [ "$live_sha" = "$main_sha" ]; then
    write_state "$state_file" "$live_sha" "" 0 || true
    exit 0
  fi

  # 6. Still behind, and either never timed or just promoted to a new live:
  #    restart the clock and allow one notice again.
  if [ -z "$since" ] || [ "$stored_live" != "$live_sha" ]; then
    write_state "$state_file" "$live_sha" "$now" 0 || true
    exit 0
  fi

  # 7. The lag passed the window and no notice went out yet: tell the owner.
  if [ "$told" -eq 0 ] && [ $((now - since)) -gt $((hours * 3600)) ]; then
    # set -e would end the tick on a failed queue write, so the send is
    # tested as a condition and told stays 0 when it fails.
    if notice_owner "disinto: live has not caught up with main for ${hours} h (live ${live_sha:0:7}, main ${main_sha:0:7}), no rollout promoted since $(iso_utc "$since"). Rollouts may be on hold (rollout/HOLD on the tape), waiting after a rollback, or the rollout tool may be broken; a disinto-admin push of live to a commit of main unblocks it (docs/updating-factory.md)."; then
      write_state "$state_file" "$live_sha" "$since" 1 || true
    else
      write_state "$state_file" "$live_sha" "$since" 0 || true
    fi
  fi

  exit 0
}

main
