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
# Checks:
#   entry shape against docs/design/notes/issue-writing.md (#1903)
#   depends_on names an unknown id (#1904)
#   a depends_on cycle (#1904)
#   two entries change the same file and neither reaches the other (#1904)
#   more than 2 code files under ## Affected files (WARN, #1905)
#   a path also listed by an open backlog issue (WARN, #1905)
#
# Usage:
#   tools/pitch-lint.sh FILE [BACKLOG_JSON]
#
# BACKLOG_JSON, when given, is a file holding a JSON array of issues as the
# forge lists them (.number, .body). A missing file or a value that is not a
# JSON array is one WARN and overlap is not checked. Warnings never change
# the exit code.
#
# Exit:
#   0  no ERROR
#   1  at least one ERROR (including a missing, empty or unparseable block)
#   2  FILE not given or missing, or an extra argument (usage on stderr,
#      nothing on stdout)
#
# #1905 reuses lint_affected. It does not add a second parser: entries come
# from lib/sprint-filer.sh.
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

# lint_affected BODY — paths an entry changes, one per line, no repeats.
# Every backtick-quoted token on the lines that start with `- ` between
# `## Affected files` and the next line starting `## `. #1905 reuses it.
lint_affected() {
  local body="$1"
  awk '
    $0 == "## Affected files" { in_sec = 1; next }
    in_sec && /^## / { in_sec = 0 }
    in_sec && /^- / {
      rest = $0
      while (match(rest, /`[^`]*`/)) {
        tok = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (tok == "" || (tok in seen)) {
          continue
        }
        seen[tok] = 1
        print tok
      }
    }
  ' <<<"$body"
}

# lint_line_has LIST ITEM — 0 when ITEM is one whole line of LIST.
lint_line_has() {
  local list="$1"
  local item="$2"
  local line
  [ -n "$item" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = "$item" ]; then
      return 0
    fi
  done <<<"$list"
  return 1
}

# lint_graph JSON — the chain between entries of one block (#1904).
# Unknown depends_on ids, a cycle, and an unchained same-file pair are
# ERRORs. Reach is a breadth-first walk of depends_on that skips unknown
# ids; blocks have fewer than 20 entries, so the walk is a bash loop.
lint_graph() {
  local entries="$1"
  local n i j id dep path next qi src reached walk_gen
  local -a ids=() deps=() affected=() reach_of=() queue=()
  local -A known=() id_index=() unk_seen=() walk_seen=()

  n="$(jq 'length' <<<"$entries")"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(jq -r --argjson i "$i" '.[$i].id // ""' <<<"$entries")"
    ids+=("$id")
    if [ -n "$id" ] && [ -z "${id_index[$id]+x}" ]; then
      id_index["$id"]="$i"
      known["$id"]=1
    fi
    deps+=("$(jq -r --argjson i "$i" '
      (.[$i].depends_on // []) | if type == "array" then .[] else empty end
    ' <<<"$entries")")
    affected+=("$(lint_affected "$(jq -r --argjson i "$i" '.[$i].body // ""' <<<"$entries")")")
    reach_of+=("")
    i=$((i + 1))
  done

  # Unknown id: a depends_on name that is not an entry of this block.
  i=0
  while [ "$i" -lt "$n" ]; do
    id="${ids[$i]}"
    walk_gen=$((i + 1))
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      [ "${unk_seen[$dep]:-0}" = "$walk_gen" ] && continue
      unk_seen["$dep"]="$walk_gen"
      if [ -z "${known[$dep]+x}" ]; then
        lint_err "$id" "depends_on names unknown id ${dep}"
      fi
    done <<<"${deps[$i]}"
    i=$((i + 1))
  done

  # Reach: ids each entry reaches through depends_on, transitively.
  # Unknown ids are not enqueued and not followed.
  i=0
  while [ "$i" -lt "$n" ]; do
    id="${ids[$i]}"
    walk_gen=$((i + 1))
    queue=()
    reached=""
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      [ -n "${known[$dep]+x}" ] || continue
      queue+=("$dep")
    done <<<"${deps[$i]}"
    qi=0
    while [ "$qi" -lt "${#queue[@]}" ]; do
      dep="${queue[$qi]}"
      qi=$((qi + 1))
      [ "${walk_seen[$dep]:-0}" = "$walk_gen" ] && continue
      walk_seen["$dep"]="$walk_gen"
      reached+="${dep}"$'\n'
      src="${id_index[$dep]}"
      while IFS= read -r next; do
        [ -z "$next" ] && continue
        [ -n "${known[$next]+x}" ] || continue
        queue+=("$next")
      done <<<"${deps[$src]}"
    done
    reach_of[i]="$reached"
    # Cycle: the entry is among the ids its own depends_on reach.
    if lint_line_has "$reached" "$id"; then
      lint_err "$id" "depends_on cycle through ${id}"
    fi
    i=$((i + 1))
  done

  # Same file: a before b, a shared path, and neither reaches the other.
  i=0
  while [ "$i" -lt "$n" ]; do
    j=$((i + 1))
    while [ "$j" -lt "$n" ]; do
      if lint_line_has "${reach_of[$i]}" "${ids[$j]}" \
        || lint_line_has "${reach_of[$j]}" "${ids[$i]}"; then
        j=$((j + 1))
        continue
      fi
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        if lint_line_has "${affected[$j]}" "$path"; then
          lint_err "${ids[$j]}" "changes ${path} like ${ids[$i]}; chain them with depends_on"
        fi
      done <<<"${affected[$i]}"
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# lint_code_count PATHS — how many paths are code files. A path that starts
# with tests/ or ends in .md is not code (the acceptance test does not count;
# a formula TOML does).
lint_code_count() {
  local paths="$1"
  local path n=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in
      tests/*|*.md) continue ;;
    esac
    n=$((n + 1))
  done <<<"$paths"
  printf '%s\n' "$n"
}

# lint_files ENTRIES [BACKLOG_JSON] — the two judgement warnings (#1905).
# Code-file ceiling first, then overlap with the open backlog. The backlog
# pass runs only when BACKLOG_JSON was passed. A missing file, or a file
# whose top-level value is not a JSON array, is one WARN without an id.
# Warnings never change the exit code: this function only calls lint_warn.
lint_files() {
  local entries="$1"
  local backlog_json="${2-}"
  local n i id body path code_n bn j bnum bfiles
  local -a ids=() affected=()

  n="$(jq 'length' <<<"$entries")"
  i=0
  while [ "$i" -lt "$n" ]; do
    id="$(jq -r --argjson i "$i" '.[$i].id // ""' <<<"$entries")"
    body="$(jq -r --argjson i "$i" '.[$i].body // ""' <<<"$entries")"
    ids+=("$id")
    affected+=("$(lint_affected "$body")")
    code_n="$(lint_code_count "${affected[$i]}")"
    if [ "$code_n" -gt 2 ]; then
      lint_warn "$id" "${code_n} code files under ## Affected files (ceiling 2)"
    fi
    i=$((i + 1))
  done

  # Overlap with the open backlog, only when a list was given.
  [ "$#" -ge 2 ] || return 0
  if [ ! -f "$backlog_json" ] || ! jq -e 'type == "array"' "$backlog_json" >/dev/null 2>&1; then
    lint_warn "" "backlog list unreadable; overlap not checked"
    return 0
  fi

  bn="$(jq 'length' "$backlog_json")"
  j=0
  while [ "$j" -lt "$bn" ]; do
    bnum="$(jq -r --argjson j "$j" '.[$j].number // ""' "$backlog_json")"
    bfiles="$(lint_affected "$(jq -r --argjson j "$j" '.[$j].body // ""' "$backlog_json")")"
    i=0
    while [ "$i" -lt "$n" ]; do
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        if lint_line_has "$bfiles" "$path"; then
          lint_warn "${ids[$i]}" "${path} is also in open issue #${bnum}"
        fi
      done <<<"${affected[$i]}"
      i=$((i + 1))
    done
    j=$((j + 1))
  done
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
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ ! -f "$1" ]; then
    echo "usage: pitch-lint.sh FILE [BACKLOG_JSON]" >&2
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
  lint_graph "$entries"
  if [ "$#" -eq 2 ]; then
    lint_files "$entries" "$2"
  else
    lint_files "$entries"
  fi
  lint_report "$file"
  if [ "$LINT_ERRORS" -gt 0 ]; then
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  pitch_lint_main "$@"
fi
