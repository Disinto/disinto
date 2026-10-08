#!/usr/bin/env bash
# =============================================================================
# planner/pitch-or-idle.sh — open the ladder pitch, or stay idle (#1978)
#
# A rung is a pitch the owner decides. This file opens that pitch in bash,
# or prints `session` so the caller may run one planning session. It does
# not call agent_run, does not source lib/env.sh, and does not check that a
# rung's probe already exists in the ops repo. The owner adds that probe to
# the rung pitch before merging.
#
# Functions (sourced by planner/planner-run.sh):
#   planner_pitch_or_idle
#     One line, or nothing:
#       held          planner_pitch_pending printed a number. Do not open.
#       (nothing, 1)  planner_pitch_pending returned 1.
#       opened <n>    the ladder printed a rung. Write that rung's pitch and
#                     call planner_pitch_open with the title, the slug (the
#                     rung id), and the file. No probe arguments. <n> is the
#                     number planner_pitch_open printed.
#       session       the ladder printed nothing and no pitch is pending.
#   planner_publish_session_pitch
#     Reads ${PLANNER_PITCH_FILE:-/tmp/planner-pitch.md}. A missing file
#     returns 0. The first line must be `# Sprint: <title>`. The slug is
#     that title, lowercased, every other character turned into `-`,
#     squeezed. pitch_sprint_block failure or `filer:begin` returns 1.
#     effect `none`, or a probes/<name>.sh path that is already a file
#     under $OPS_REPO_ROOT: planner_pitch_open with no probe arguments.
#     That same path, missing in ops, and a non-empty
#     ${PLANNER_PROBE_FILE:-/tmp/planner-probe.sh}: pass that file and the
#     effect path as PROBE_SRC and PROBE_DEST. That path missing, and no
#     probe file: return 0, do not open. Any other effect: return 1.
#
# Sources planner/ladder.sh and planner/pitch-open.sh. No network of its
# own: the opener it calls is the only forge client.
# =============================================================================
set -euo pipefail

# shellcheck source=ladder.sh
source "$(dirname "${BASH_SOURCE[0]}")/ladder.sh"
# shellcheck source=pitch-open.sh
source "$(dirname "${BASH_SOURCE[0]}")/pitch-open.sh"

# Same shape planner/pitch-open.sh accepts as PROBE_DEST. Two dots are
# rejected even though the character class would allow them.
_PLANNER_EFFECT_RE='^probes/[A-Za-z0-9][A-Za-z0-9.-]*\.sh$'

# _planner_pitch_slug TITLE — lowercase, every other character to `-`, squeezed.
_planner_pitch_slug() {
  local slug
  slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-')"
  slug="${slug#-}"
  slug="${slug%-}"
  printf '%s\n' "$slug"
}

# _planner_rung_pitch_write RUNG DEST — write RUNG's pitch to DEST and print
# its title. Return 1 for an unknown rung. The paragraph ends with the
# sentence the owner reads: the planner pitches the rung and does not run it.
# No filer block, no sub-issues. The effect file is not consulted.
_planner_rung_pitch_write() {
  local rung="$1" dest="$2"
  local title effect paragraph
  case "$rung" in
    sense)
      title="Sense"
      effect="probes/can-sense.sh"
      paragraph="An action container on the factory host runs a read-only inventory (CPU, memory, disk, docker, LXD) and stores it as an artifact."
      ;;
    provision)
      title="Provision"
      effect="probes/can-provision.sh"
      paragraph='An action starts a named LXC container in its own LXD project, on ai-pool (`/opt/ai`) only, reports its address, and deletes it.'
      ;;
    reach)
      title="Reach the porter"
      effect="probes/can-reach-porter.sh"
      paragraph="An action container logs in to the porter host, disinto.ai, and runs whoami and uname."
      ;;
    deploy)
      title="Deploy the porter"
      effect="probes/can-deploy-porter.sh"
      paragraph="An action runs porter-install.sh at a ref on disinto.ai and verifies it with the status verb."
      ;;
    replicate)
      title="Replicate"
      effect="probes/can-replicate.sh"
      paragraph="Provision a container, install disinto at a ref, and run its acceptance tests and claim checks against the new instance."
      ;;
    *)
      return 1
      ;;
  esac
  cat >"$dest" <<EOF
# Sprint: ${title}

## What this enables

${paragraph} The planner pitches it and does not run it.

<!-- sprint:begin -->
class: internal
effect: ${effect}
expect: >= 1
soak: 14d
<!-- sprint:end -->
EOF
  printf '%s\n' "$title"
}

# planner_pitch_or_idle — see the file header. Does not call agent_run.
planner_pitch_or_idle() {
  local pending="" pending_rc=0
  pending="$(planner_pitch_pending)" || pending_rc=$?
  if [ "$pending_rc" -ne 0 ]; then
    return 1
  fi
  if [ -n "$pending" ]; then
    printf 'held\n'
    return 0
  fi

  local rung=""
  rung="$(ladder_lowest_gap)" || return 1
  rung="${rung%%$'\n'*}"
  rung="${rung#"${rung%%[![:space:]]*}"}"
  rung="${rung%"${rung##*[![:space:]]}"}"
  if [ -z "$rung" ]; then
    printf 'session\n'
    return 0
  fi

  local pitch title number=""
  pitch="$(mktemp)"
  title="$(_planner_rung_pitch_write "$rung" "$pitch")" || return 1
  number="$(planner_pitch_open "$title" "$rung" "$pitch")" || return 1
  number="${number%%$'\n'*}"
  if [ -z "$number" ]; then
    return 1
  fi
  printf 'opened %s\n' "$number"
}

# planner_publish_session_pitch — see the file header.
planner_publish_session_pitch() {
  local file="${PLANNER_PITCH_FILE:-/tmp/planner-pitch.md}"
  if [ ! -f "$file" ]; then
    return 0
  fi

  local first title
  IFS= read -r first <"$file" || return 1
  case "$first" in
    "# Sprint: "*) title="${first#"# Sprint: "}" ;;
    *) return 1 ;;
  esac
  title="${title#"${title%%[![:space:]]*}"}"
  title="${title%"${title##*[![:space:]]}"}"
  [ -n "$title" ] || return 1

  if grep -qF 'filer:begin' "$file"; then
    return 1
  fi
  local block effect slug
  block="$(pitch_sprint_block "$file")" || return 1
  effect="$(sprint_field "$block" effect)"
  slug="$(_planner_pitch_slug "$title")"
  [ -n "$slug" ] || return 1

  if [ "$effect" = "none" ]; then
    planner_pitch_open "$title" "$slug" "$file"
    return
  fi

  # A probe path the ops repo already has is opened with the pitch alone.
  # A missing one is added only when this same pitch wrote the probe file.
  # Anything else is not a session pitch.
  case "$effect" in
    *..*) return 1 ;;
  esac
  if [[ ! "$effect" =~ $_PLANNER_EFFECT_RE ]]; then
    return 1
  fi

  # shellcheck disable=SC2154 # OPS_REPO_ROOT is set by lib/env.sh in planner-run.sh
  if [ -f "${OPS_REPO_ROOT}/${effect}" ]; then
    planner_pitch_open "$title" "$slug" "$file"
    return
  fi

  local probe="${PLANNER_PROBE_FILE:-/tmp/planner-probe.sh}"
  if [ -f "$probe" ] && [ -s "$probe" ]; then
    planner_pitch_open "$title" "$slug" "$file" "$probe" "$effect"
    return
  fi
  return 0
}
