#!/usr/bin/env bash
# =============================================================================
# lib/claims.sh — read claim files from the ops repo (#1640)
#
# The factory's world model is claims: one TOML file per claim in the ops
# repo, `claims/<id>.toml`. Each file is a statement plus a check the factory
# runs itself. This lib only reads those files. Called by
# tools/claim-proposals.sh (#1641), tools/claim-checks.sh (#1642), and
# tools/claims-report.sh (#1645).
#
# Sourced from the caller:
#   source "$(dirname "$0")/claims.sh"
#
# Storage (env-overridable, the test seam):
#   $CLAIMS_DIR    — claim TOML dir; default ${OPS_REPO_ROOT}/claims
#   $OPS_REPO_ROOT — ops repo clone (fallback location for the default dir)
#
# Claim format (documented here so the ops-side writers stay in sync):
#
#   statement = "a dev proposal comes back, merged or rejected, within 48 hours"
#   class     = "internal"                  # deploy | experiment | internal
#   check     = "probes/dev-unreturned.sh"  # prints one number
#   expect    = "<= 0.2"                    # as a sprint block's expect
#   window    = "7d"                        # as a sprint block's soak
#   rests_on  = []                          # claim ids
#
# A claim's status (provisional, held, challenged) is read from the tape,
# never written in the file. This lib does not read or write the tape.
#
# Functions:
#   claim_ids
#     -> ids in ${CLAIMS_DIR:-${OPS_REPO_ROOT}/claims}, sorted, one per line.
#        Each `*.toml` file name without `.toml`, and only when the name
#        matches `^[a-z][a-z0-9-]*$`. A missing dir prints nothing, rc 0.
#        Implemented by _claim_ids_in (also used by tools/claim-checks.sh).
#   claim_field ID KEY
#     -> value of KEY, read with python3 tomllib (as lib/signature.sh does).
#        An array prints its items space-separated. Missing file or key:
#        nothing, rc 0. A file that does not parse: nothing, rc 1.
#   claim_valid ID
#     -> rc 0 when `statement` is not empty, `class` is one of deploy /
#        experiment / internal, `check` starts with `probes/` and holds no
#        `..`, `sprint_expect_met 0 "<expect>"` does not return 2, and
#        `sprint_duration_seconds "<window>"` prints more than 0. Otherwise
#        one line naming the first bad field to stderr, rc 1. Fields are
#        checked in that order (statement, class, check, expect, window).
#
# Hermetic: python3 tomllib + lib/sprint-block.sh. No network, no agent,
# no secrets (AD-006).
# =============================================================================
set -euo pipefail

# shellcheck source=sprint-block.sh
source "$(dirname "${BASH_SOURCE[0]}")/sprint-block.sh"

# _claims_dir — ${CLAIMS_DIR:-${OPS_REPO_ROOT}/claims}, set -u safe when
# OPS_REPO_ROOT is unset (the default expansion is then `/claims`).
_claims_dir() {
  printf '%s\n' "${CLAIMS_DIR:-${OPS_REPO_ROOT:-}/claims}"
}

# _claim_fail FIELD — one stderr line naming the first bad field. Returns 0
# so the caller can `return 1` without tripping set -e.
_claim_fail() {
  printf 'bad field: %s\n' "$1" >&2
}

# _claim_ids_in DIR SUFFIX — sorted ids of regular files in DIR whose names
# end in the literal SUFFIX (`.toml`, `.current`) and match
# `^[a-z][a-z0-9-]*$` after that suffix is removed. A missing directory
# prints nothing and returns 0. One listing, so claim_ids and
# tools/claim-checks.sh do not each carry the filter.
_claim_ids_in() {
  local dir="$1" suffix="$2" f base
  [ -d "$dir" ] || return 0
  local -a ids=()
  for f in "$dir"/*"$suffix"; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    base="${base%"$suffix"}"
    if [[ "$base" =~ ^[a-z][a-z0-9-]*$ ]]; then
      ids+=("$base")
    fi
  done
  [ "${#ids[@]}" -eq 0 ] && return 0
  printf '%s\n' "${ids[@]}" | LC_ALL=C sort
}

# claim_ids — sorted claim ids, one per line. Names that are not
# `^[a-z][a-z0-9-]*$` (Bad_Name.toml, underscores, a leading digit) are
# skipped. A missing directory prints nothing and returns 0.
claim_ids() {
  _claim_ids_in "$(_claims_dir)" .toml
}

# claim_field ID KEY — print the value of KEY from <dir>/<ID>.toml.
#   An array prints its items space-separated (no trailing space). A missing
#   file or a missing key prints nothing and returns 0. A file that does not
#   parse prints nothing and returns 1. python3 tomllib only, stderr of the
#   parser is discarded so a caller's stderr stays the validation line.
claim_field() {
  local id="${1:-}" key="${2:-}"
  local dir file val rc
  dir="$(_claims_dir)"
  file="${dir}/${id}.toml"
  if [ ! -f "$file" ]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  rc=0
  val="$(TOML_FILE="$file" CLAIM_KEY="$key" python3 -c '
import os, sys, tomllib
try:
    with open(os.environ["TOML_FILE"], "rb") as fh:
        data = tomllib.load(fh)
except FileNotFoundError:
    sys.exit(0)
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(0)
key = os.environ["CLAIM_KEY"]
if key not in data:
    sys.exit(0)
v = data[key]

def scalar(item):
    if isinstance(item, bool):
        return "true" if item else "false"
    if isinstance(item, int):
        return str(item)
    if isinstance(item, float):
        return format(item, ".15g")
    if isinstance(item, str):
        return item
    return None

if isinstance(v, list):
    parts = []
    for item in v:
        s = scalar(item)
        parts.append(s if s is not None else "")
    sys.stdout.write(" ".join(parts))
else:
    s = scalar(v)
    if s is None:
        sys.exit(0)
    sys.stdout.write(s)
' 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  fi
  return 0
}

# claim_valid ID — rc 0 when the claim file is well-formed, else rc 1 and
# one stderr line naming the first bad field (statement, class, check,
# expect, window — in that order).
#   statement  not empty
#   class      deploy | experiment | internal
#   check      starts with probes/ and holds no `..`
#   expect     sprint_expect_met 0 "<expect>" does not return 2
#   window     sprint_duration_seconds "<window>" prints more than 0
# An unreadable or unparseable file fails on statement (the value cannot be
# read, so it is empty). Status is not a file field and is not checked.
claim_valid() {
  local id="${1:-}"
  local statement class check expect window secs rc

  statement="$(claim_field "$id" statement)" || statement=""
  if [ -z "$statement" ]; then
    _claim_fail statement
    return 1
  fi

  class="$(claim_field "$id" class)" || class=""
  case "$class" in
    deploy|experiment|internal) ;;
    *)
      _claim_fail class
      return 1
      ;;
  esac

  check="$(claim_field "$id" check)" || check=""
  if [[ "$check" != probes/* ]] || [[ "$check" == *..* ]]; then
    _claim_fail check
    return 1
  fi

  expect="$(claim_field "$id" expect)" || expect=""
  rc=0
  sprint_expect_met 0 "$expect" || rc=$?
  if [ "$rc" -eq 2 ]; then
    _claim_fail expect
    return 1
  fi

  window="$(claim_field "$id" window)" || window=""
  secs="$(sprint_duration_seconds "$window")"
  if ! [[ "$secs" =~ ^[0-9]+$ ]] || [ "$secs" -le 0 ]; then
    _claim_fail window
    return 1
  fi
  return 0
}
