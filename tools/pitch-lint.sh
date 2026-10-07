#!/usr/bin/env bash
# =============================================================================
# tools/pitch-lint.sh — lint a pitch's sub-issue block (#1903)
#
# A pitch is an ops-repo file sprints/<slug>.md. Its ## Sub-issues block
# (<!-- filer:begin --> … <!-- filer:end -->) becomes backlog issues when the
# pitch merges. This check, zero tokens and no network, reads that block with
# the filer's own parsers and reports each entry against
# docs/design/notes/issue-writing.md.
#
# Usage:
#   tools/pitch-lint.sh FILE
#
# Exit:
#   0  no ERROR
#   1  at least one ERROR (including a missing, empty or unparseable block)
#   2  FILE not given or missing (usage on stderr, nothing on stdout)
#
# Later checks (#1904, #1905) call lint_err / lint_warn. They do not add a
# second parser: entries come from lib/sprint-filer.sh.
# =============================================================================
set -euo pipefail

# Findings. lint_err / lint_warn are the only writers; lint_report prints them.
LINT_ERRORS=0
LINT_WARNINGS=0
LINT_FINDINGS=()

# lint_err ID MSG — an ERROR finding. An empty ID is the block-level finding
# (no entry to name): `- ERROR: MSG`. Otherwise `- ERROR ID: MSG`.
lint_err() {
  local id="$1"
  local msg="$2"
  if [ -n "$id" ]; then
    LINT_FINDINGS+=("- ERROR ${id}: ${msg}")
  else
    LINT_FINDINGS+=("- ERROR: ${msg}")
  fi
  LINT_ERRORS=$((LINT_ERRORS + 1))
}

# lint_warn ID MSG — a WARN finding. Same ID shape as lint_err.
lint_warn() {
  local id="$1"
  local msg="$2"
  if [ -n "$id" ]; then
    LINT_FINDINGS+=("- WARN ${id}: ${msg}")
  else
    LINT_FINDINGS+=("- WARN: ${msg}")
  fi
  LINT_WARNINGS=$((LINT_WARNINGS + 1))
}

# True when a line starting `- [ ]` sits between ## Acceptance criteria and
# the next ## heading. The parsed body has already lost its YAML indent.
body_has_unchecked() {
  local body="$1"
  awk '
    $0 == "## Acceptance criteria" { in_sec = 1; next }
    in_sec && /^## / { in_sec = 0 }
    in_sec && /^- \[ \]/ { found = 1 }
    END { exit (found ? 0 : 1) }
  ' <<<"$body"
}

# True when ## Acceptance test's section contains tests/acceptance/issue-.
body_names_acceptance_test() {
  local body="$1"
  awk '
    $0 == "## Acceptance test" { in_sec = 1; next }
    in_sec && /^## / { in_sec = 0 }
    in_sec && index($0, "tests/acceptance/issue-") { found = 1 }
    END { exit (found ? 0 : 1) }
  ' <<<"$body"
}

# lint_entries JSON — one pass, block order, over the filer's JSON array.
lint_entries() {
  local entries="$1"
  local n i id title body lines h
  local -a required=(
    "Problem"
    "Proposed solution"
    "Affected files"
    "Documentation"
    "Acceptance criteria"
    "Acceptance test"
  )
  local -A seen=()

  n="$(jq 'length' <<<"$entries")"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(jq -r --argjson i "$i" '.[$i].id // ""' <<<"$entries")"
    title="$(jq -r --argjson i "$i" '.[$i].title // ""' <<<"$entries")"
    body="$(jq -r --argjson i "$i" '.[$i].body // ""' <<<"$entries")"
    lines="$(jq -r --argjson i "$i" '
      .[$i].body // "" | if . == "" then 0 else (split("\n") | length) end
    ' <<<"$entries")"

    if [ -n "${seen[$id]+x}" ]; then
      lint_err "$id" "duplicate id"
    else
      seen[$id]=1
    fi
    if [ -z "$title" ]; then
      lint_err "$id" "empty title"
    fi
    if [ "$lines" -gt 100 ]; then
      lint_err "$id" "body has ${lines} lines (max 100)"
    fi
    for h in "${required[@]}"; do
      if ! printf '%s\n' "$body" | grep -Fxq -- "## ${h}"; then
        lint_err "$id" "missing ## ${h}"
      fi
    done
    if ! printf '%s\n' "$body" | grep -Fxq -- "## Existing tests"; then
      lint_warn "$id" "missing ## Existing tests"
    fi
    if ! body_has_unchecked "$body"; then
      lint_err "$id" "no '- [ ]' under ## Acceptance criteria"
    fi
    if ! body_names_acceptance_test "$body"; then
      lint_err "$id" "no tests/acceptance/issue- in ## Acceptance test"
    fi
    i=$((i + 1))
  done
}

# Markdown report. The path is always sprints/<basename>, whatever FILE was.
lint_report() {
  local file="$1"
  local base
  base="$(basename -- "$file")"
  printf '### Pitch lint: sprints/%s\n\n' "$base"
  if [ "${#LINT_FINDINGS[@]}" -gt 0 ]; then
    printf '%s\n' "${LINT_FINDINGS[@]}"
  fi
  printf '\nErrors: %s, warnings: %s\n' "$LINT_ERRORS" "$LINT_WARNINGS"
}

pitch_lint_main() {
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: pitch-lint.sh FILE" >&2
    exit 2
  fi

  local file="$1"
  local repo_root raw entries
  # BASH_SOURCE, not $0: a caller that sources this file still resolves the
  # factory root to this repo, and FACTORY_ROOT makes sprint-filer skip env.sh.
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export FACTORY_ROOT="$repo_root"
  : "${FORGE_FILER_TOKEN:=unused}"
  : "${FORGE_API:=unused}"
  export FORGE_FILER_TOKEN FORGE_API

  # shellcheck source=../lib/sprint-filer.sh
  source "$repo_root/lib/sprint-filer.sh"

  LINT_ERRORS=0
  LINT_WARNINGS=0
  LINT_FINDINGS=()

  raw=""
  entries=""
  if raw="$(parse_subissues_block "$file")"; then
    entries="$(printf '%s' "$raw" | parse_subissue_entries)"
  fi

  # jq -e on empty input (jq 1.6) produces nothing and exits 0, so an
  # empty capture must be rejected before the type check.
  if [ -z "$entries" ] || ! printf '%s' "$entries" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    lint_err "" "no sub-issue entries (filer block missing, empty or unparseable)"
    lint_report "$file"
    exit 1
  fi

  lint_entries "$entries"
  lint_report "$file"
  if [ "$LINT_ERRORS" -gt 0 ]; then
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pitch_lint_main "$@"
fi
