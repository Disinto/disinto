#!/usr/bin/env bash
# =============================================================================
# lib/pitch.sh — read a pitch file, the ops-repo PR that adds sprints/<slug>.md
#
# A pitch is a gardener-generated ops-repo PR that adds sprints/<slug>.md —
# the proposal for one vision issue. When the owner merges it, the project
# gets the sprint's milestone and its sub-issues and the tape gets an approved
# sprint proposal; when the owner closes it unmerged, the tape gets a rejected
# one. Both paths need the pitch's machine-readable content, and only the
# merged-pitch (#1889) and reject-pitch (#1891) steps read it.
#
# The pitch file carries two pieces of machine-readable content that this lib
# reads:
#   * the sprint block — the lines strictly between the first
#     `<!-- sprint:begin -->` and the next `<!-- sprint:end -->` marker. They
#     are exactly the `class`, `effect`, `expect`, `soak` (and optional
#     `rests_on`) lines of a sprint milestone's description, i.e. the shape
#     lib/sprint-block.sh (#1629) parses.
#   * the purpose — the first paragraph under the `## What this enables`
#     heading.
#
# Functions (sourced; no callers yet — #1889 and #1892 read them):
#   pitch_sprint_block FILE
#     -> the lines strictly between the first line of FILE containing
#        `<!-- sprint:begin -->` and the next line containing
#        `<!-- sprint:end -->`, unchanged. Prints nothing and returns 1 when
#        FILE is missing, either marker is missing, or
#        `sprint_field "$block" class` is empty.
#   pitch_purpose FILE
#     -> the first paragraph under FILE's `## What this enables` heading.
#        Skips the blank lines right after the heading, then prints lines up
#        to the first blank line, or the first line that starts with `#` or
#        `<!--`. Prints nothing and returns 1 when the heading is missing or
#        the paragraph is empty.
#
# Notes:
#   * Hermetic: pure bash. Sources lib/sprint-block.sh for `sprint_field` (the
#     same parser the milestone path uses, #1629). No network, no forge, no
#     agent, no secrets (AD-006).
#   * `pitch_sprint_block` requires a non-empty `class` line: the merged-pitch
#     path sets the tape proposal's `class` from it, so a pitch without a
#     class is malformed and cannot become a sprint.
#
# Sourced from the caller:
#   source "$(dirname "$0")/lib/pitch.sh"
# =============================================================================
set -euo pipefail

# shellcheck source=sprint-block.sh
source "$(dirname "${BASH_SOURCE[0]}")/sprint-block.sh"

# _pitch_trim_left LINE — LINE with leading whitespace removed (same trim
# idiom as lib/sprint-block.sh's _sprint_trim, leading side only).
_pitch_trim_left() {
  printf '%s' "${1#"${1%%[![:space:]]*}"}"
}

# _pitch_is_blank LINE — rc 0 when LINE is empty or all whitespace.
_pitch_is_blank() {
  [[ -z "$(_pitch_trim_left "$1")" ]]
}

# _pitch_is_heading LINE — rc 0 when LINE (ignoring leading whitespace) is the
# `## What this enables` heading.
_pitch_is_heading() {
  [[ "$(_pitch_trim_left "$1")" == '## What this enables'* ]]
}

# pitch_sprint_block FILE — the lines strictly between the first `<!--
# sprint:begin -->` and the next `<!-- sprint:end -->` in FILE, unchanged.
# Prints nothing and returns 1 when FILE is missing, either marker is missing,
# or `sprint_field "$block" class` is empty.
pitch_sprint_block() {
  local file="${1:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 1
  fi
  local block="" line
  local in_block=0 end_seen=0
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [ "$in_block" = 1 ]; then
      if [[ "$line" == *'<!-- sprint:end -->'* ]]; then
        end_seen=1
        break
      fi
      block+="$line"$'\n'
    else
      if [[ "$line" == *'<!-- sprint:begin -->'* ]]; then
        in_block=1
      fi
    fi
  done < "$file"
  if [ "$in_block" = 0 ] || [ "$end_seen" = 0 ]; then
    return 1
  fi
  local class_val
  class_val="$(sprint_field "$block" class)"
  if [ -z "$class_val" ]; then
    return 1
  fi
  printf '%s' "$block"
  return 0
}

# pitch_purpose FILE — the first paragraph under FILE's `## What this enables`
# heading. Skips blank lines after the heading; prints lines up to the first
# blank line, or the first line that starts with `#` or `<!--`. Prints
# nothing and returns 1 when the heading is missing or the paragraph is empty.
pitch_purpose() {
  local file="${1:-}"
  if [[ -z "$file" || ! -f "$file" ]]; then
    return 1
  fi
  local line
  local seen_heading=0 started=0
  local para=""
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [ "$seen_heading" = 0 ]; then
      if _pitch_is_heading "$line"; then
        seen_heading=1
      fi
      continue
    fi
    if _pitch_is_blank "$line"; then
      if [ "$started" = 1 ]; then
        break
      fi
      continue
    fi
    if [[ "$line" == '#'* || "$line" == '<!--'* ]]; then
      break
    fi
    started=1
    para+="$line"$'\n'
  done < "$file"
  if [ "$started" = 0 ]; then
    return 1
  fi
  printf '%s' "$para"
  return 0
}
