#!/usr/bin/env bash
# sprint-block.sh — parse the sprint block of a milestone description (#1629)
#
# A sprint is a Forgejo milestone. Its description carries a small sprint
# block that names the sprint's nature and how its effect is measured. The dev
# poll, the sprint tape (lib/sprint-tape.sh, #1618) and the sprint outcome tool
# all need these fields; nothing parsed them.
#
# Block format (lines, in a Forgejo milestone description):
#
#   class: deploy            (deploy | experiment | internal)
#   level: reachable         (optional: held | made | reachable | reached; default held)
#   effect: probes/<name>.sh (a path under the ops repo, or none)
#   expect: >= 3             (one of >= <= > < ==, a space, a number)
#   soak: 7d                 (an integer followed by d or h)
#   rests_on: a, b           (optional: claim ids, comma-separated)
#
# Function (sourced; no callers yet):
#   sprint_field TEXT KEY
#     -> value of the first line of TEXT matching `^KEY:[[:space:]]*(.*)$`,
#         with leading and trailing whitespace removed. No match: print
#         nothing and return 0.
#   sprint_duration_seconds VALUE
#     -> VALUE in seconds (`7d` -> 604800, `48h` -> 172800); anything else
#         (not `<int>d`/`<int>h`) prints `0`.
#   sprint_soak_seconds TEXT
#     -> sprint_duration_seconds of the `soak` field of TEXT; a missing soak
#         line prints `0`.
#   sprint_expect_met VALUE EXPECT
#     -> rc 0 when met, rc 1 when not met, rc 2 when VALUE or EXPECT is
#         malformed. EXPECT is an operator (`>=`, `<=`, `>`, `<`, `==`), a
#         space and a number; VALUE is a number (integer or decimal, may be
#         negative). Comparison is done with awk, not bash integer tests.
#   sprint_level TEXT
#     -> the `level` field of TEXT: the effect-scale level the sprint aims at
#         (docs/design/proposal-loop.md §3). A missing line prints `held`
#         (the default); `held`, `made`, `reachable`, `reached` print
#         themselves. Any other word — `broke` and `none` are outcomes, not
#         aims — prints nothing and returns 1.
#   sprint_level_value LEVEL
#     -> the grade of a level on the effect scale: broke -1, none 0,
#         held 0.25, made 0.5, reachable 0.75, reached 1. Any other word
#         prints nothing and returns 1.
#
# Notes:
#   * No validation of `class` or `effect` here — callers decide.
#   * Claims (ops repo `claims/*.toml`) reuse the same `expect` and duration
#     formats, so these functions are the single parser for both.
#   * Hermetic: pure bash + awk. No network, no forge, no agent.
#
# Subsystems (sourced): none — self-contained (awk only for the expect compare).

set -euo pipefail

# _sprint_trim <s> — print s with leading and trailing whitespace removed.
# (The two `${...#...}`/`${...%...}` expansions are the standard bash trim
# idiom; they are safe under set -u because both sides default to empty when
# no non-whitespace char exists.)
_sprint_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # drop leading whitespace
  s="${s%"${s##*[![:space:]]}"}"    # drop trailing whitespace
  printf '%s' "$s"
}

# sprint_field TEXT KEY — print the value of the first line of TEXT matching
# `^KEY:[[:space:]]*(.*)$`, trimmed. No match: print nothing, return 0.
#   The match is literal: the line must start with `KEY:` (the colon anchors
#   the exact key, so `class:` never matches `classx:` or `class foo:`). The
#   remainder is the raw value; leading and trailing whitespace is removed.
sprint_field() {
  local text="${1:-}" key="${2:-}"
  local prefix="$key:"
  local line val
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [[ $line == "$prefix"* ]]; then
      val="${line#"$prefix"}"
      printf '%s\n' "$( _sprint_trim "$val" )"
      return 0
    fi
  done <<< "$text"
  return 0
}

# sprint_duration_seconds VALUE — print VALUE in seconds: `<int>d` ->
# <int>*86400, `<int>h` -> <int>*3600. Anything else (non-matching value)
# prints `0`.
#   Only non-negative integer durations are accepted; the pattern is anchored
#   so `7`, `7x`, `7.5d`, `d`, `""` all fall through to `0`.
sprint_duration_seconds() {
  local value="${1:-}"
  if [[ "$value" =~ ^([0-9]+)([dh])$ ]]; then
    local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
    if [[ "$unit" == "d" ]]; then
      printf '%s\n' $((num * 86400))
    else
      printf '%s\n' $((num * 3600))
    fi
  else
    printf '0\n'
  fi
}

# sprint_soak_seconds TEXT — print sprint_duration_seconds of the soak field
# of TEXT. A missing (or unparseable) soak line prints `0`.
#   The soak value flows through sprint_field (trimmed) so the `7d` / `48h`
#   forms are matched exactly; `soak: soon` -> 0.
sprint_soak_seconds() {
  local text="${1:-}" soak
  soak="$(sprint_field "$text" soak)" || soak=""
  sprint_duration_seconds "$soak"
}

# sprint_expect_met VALUE EXPECT — rc 0 met / rc 1 not met / rc 2 malformed.
#   VALUE: `^-?[0-9]+(\.[0-9]+)?$` or `.NNN` (integer or decimal, may be
#     negative). EXPECT: `(>=|<=|==|>|<)` + whitespace + the same number shape.
#   The comparison is evaluated in awk (numeric, so `0.12 <= 0.2` works), not
#   with bash integer tests.
sprint_expect_met() {
  local value="${1:-}" expect="${2:-}"
  if ! [[ "$value" =~ ^-?([0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]]; then
    return 2
  fi
  if ! [[ "$expect" =~ ^(>=|<=|==|>|<)[[:space:]]+(-?[0-9]+(\.[0-9]+)?|\.[0-9]+)$ ]]; then
    return 2
  fi
  local op="${BASH_REMATCH[1]}" num="${BASH_REMATCH[2]}"
  awk -v op="$op" -v v="$value" -v n="$num" 'BEGIN {
    v += 0; n += 0
    if (op == ">=") met = (v >= n)
    else if (op == "<=") met = (v <= n)
    else if (op == ">") met = (v > n)
    else if (op == "<") met = (v < n)
    else met = (v == n)
    exit (met ? 0 : 1)
  }'
}

# sprint_level TEXT — print the effect-scale level the sprint aims at
# (docs/design/proposal-loop.md §2, §3). A missing `level:` line prints the
# default `held`. Only the four aim-words are accepted: `held`, `made`,
# `reachable`, `reached`. Anything else (including `broke` and `none`, which
# are outcomes a sprint does not aim at) prints nothing and returns 1.
#   The value reaches here already trimmed by sprint_field, so
#   `level:   made  ` reads as `made`.
sprint_level() {
  local text="${1:-}" level
  level="$(sprint_field "$text" level)"
  if [ -z "$level" ]; then
    printf 'held\n'
    return 0
  fi
  case "$level" in
    held | made | reachable | reached)
      printf '%s\n' "$level"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# sprint_level_value LEVEL — print the grade of a level on the effect scale
# (docs/design/proposal-loop.md §3): broke -1, none 0, held 0.25, made 0.5,
# reachable 0.75, reached 1. An unknown level prints nothing and returns 1.
#   `broke` and `none` are not aims (sprint_level refuses them) but they are
#   grades a sprint's outcome can land on, so the scale names them too.
sprint_level_value() {
  local level="${1:-}"
  case "$level" in
    broke)     printf '%s\n' -1 ;;
    none)      printf '%s\n' 0 ;;
    held)      printf '%s\n' 0.25 ;;
    made)      printf '%s\n' 0.5 ;;
    reachable) printf '%s\n' 0.75 ;;
    reached)   printf '%s\n' 1 ;;
    *)         return 1 ;;
  esac
}
