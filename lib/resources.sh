#!/usr/bin/env bash
# resources.sh — structured RESOURCES.md host blocks (#1304)
#
# Parse the structured host blocks in an ops-repo RESOURCES.md (seeded from
# RESOURCES.example.md):
#
#   ### <alias>
#   - class: meep | cpu | gpu | control
#   - ssh: user@host
#   - cap: <N concurrent>
#   - image: <optional default>
#
# A block is a `### <alias>` heading followed by `- field: value` lines, up to
# the next heading of any level. Prose bullets (e.g. `- **Specs**: ...`) are
# ignored — only the four fields above are recorded. A block is a HOST only if
# it has a `class:` line; a host without a usable `cap:` has cap 0 (never
# picked). Fenced code blocks are skipped.
#
# Public functions (used by run-experiment.sh — #1293 wave 2):
#   resources_hosts <file>
#     List host aliases, one per line, in file order (class blocks only).
#   resources_field <file> <alias> <field>
#     Value of field (class|ssh|cap|image) for alias; empty output when the
#     field is absent (e.g. the optional image).
#   resources_pick <file> <class> [in_flight_counts]
#     First alias (file order) whose class matches and whose in-flight count
#     is below cap. in_flight_counts is a whitespace-separated list of
#     integers aligned with resources_hosts order (positions beyond the list
#     default to 0). First fit only — no placement policy. No SSH, no
#     network, no LLM, no file writes.
#
# Return codes: 0 = ok; 1 = file missing, alias unknown, or no host picked;
# 2 = usage error.

set -euo pipefail

# _resources_parsed <file> — emit the structured host blocks as TSV:
# alias<TAB>class<TAB>ssh<TAB>cap<TAB>image (empty column = absent).
# Returns 1 when the file is missing.
_resources_parsed() {
  local file="${1:-}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    return 1
  fi
  awk '
    function trim(s) {
      gsub(/^[ \t\r]+/, "", s)
      gsub(/[ \t\r]+$/, "", s)
      return s
    }
    function flush() {
      if (alias == "") return
      printf "%s\t%s\t%s\t%s\t%s\n", alias, \
        (seenclass ? valclass : ""), (seenssh ? valssh : ""), \
        (seencap ? valcap : ""), (seenimage ? valimage : "")
      alias = ""
      seenclass = 0; seenssh = 0; seencap = 0; seenimage = 0
      valclass = ""; valssh = ""; valcap = ""; valimage = ""
    }
    { sub(/\r$/, "") }
    /^```/ { incode = !incode; next }
    incode { next }
    /^#/ {
      flush()
      alias = ""
      if ($0 ~ /^###[ \t]/) alias = trim(substr($0, 4))
      next
    }
    alias != "" && /^[ \t]*-[ \t]+[A-Za-z0-9_]+:/ {
      line = $0
      field = line; sub(/^[ \t]*-[ \t]+/, "", field); sub(/:.*$/, "", field)
      value = line; sub(/^[ \t]*-[ \t]+[^:]*:[ \t]*/, "", value)
      if (field == "class")       { valclass = value; seenclass = 1 }
      else if (field == "ssh")    { valssh = value; seenssh = 1 }
      else if (field == "cap")    { valcap = value; seencap = 1 }
      else if (field == "image")  { valimage = value; seenimage = 1 }
    }
    END { flush() }
  ' "$file"
}

# resources_hosts <file> — list structured host aliases, one per line, in
# file order. 1 = file missing, 2 = usage.
resources_hosts() {
  local file="${1:-}" tsv
  if [ -z "$file" ]; then
    echo "usage: resources_hosts <file>" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "resources_hosts: file not found: $file" >&2
    return 1
  fi
  tsv="$(_resources_parsed "$file")" || {
    echo "resources_hosts: file not found: $file" >&2
    return 1
  }
  awk -F'\t' '$2 != "" { print $1 }' <<< "$tsv"
}

# resources_field <file> <alias> <field> — print one field value.
# 1 = file missing or alias unknown, 2 = usage (bad field name / args).
resources_field() {
  local file="${1:-}" alias="${2:-}" field="${3:-}" tsv
  if [ -z "$file" ] || [ -z "$alias" ] || [ -z "$field" ]; then
    echo "usage: resources_field <file> <alias> <field>" >&2
    return 2
  fi
  case "$field" in
    class|ssh|cap|image) ;;
    *)
      echo "resources_field: unknown field '$field' (expected class|ssh|cap|image)" >&2
      return 2
      ;;
  esac
  tsv="$(_resources_parsed "$file")" || {
    echo "resources_field: file not found: $file" >&2
    return 1
  }
  awk -F'\t' -v a="$alias" -v f="$field" '
    BEGIN { col = (f == "class" ? 2 : (f == "ssh" ? 3 : (f == "cap" ? 4 : 5))) }
    $1 == a { print $col; found = 1; exit }
    END { if (!found) exit 1 }
  ' <<< "$tsv"
}

# resources_pick <file> <class> [in_flight_counts] — print the first alias
# whose class matches and whose in-flight count is below cap.
# 1 = file missing or no host qualifies, 2 = usage.
resources_pick() {
  local file="${1:-}" class="${2:-}" counts="${3:-}"
  if [ -z "$file" ] || [ -z "$class" ]; then
    echo "usage: resources_pick <file> <class> [in_flight_counts]" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "resources_pick: file not found: $file" >&2
    return 1
  fi
  local tsv
  tsv="$(_resources_parsed "$file")" || {
    echo "resources_pick: file not found: $file" >&2
    return 1
  }

  # In-flight counts: whitespace-separated, aligned with resources_hosts
  # order (i.e. the class-bearing blocks in file order).
  local -a count_list=()
  if [ -n "$counts" ]; then
    read -r -a count_list <<< "$counts"
  fi

  local alias c cap inf capnum n=0
  while IFS=$'\t' read -r alias c _ssh cap _image; do
    [ -n "$alias" ] || continue
    # Alignment: n counts every class-bearing block in file order — the
    # resources_hosts order — so each count slot lands on the right host
    # even when other classes sit between matches.
    [ -n "$c" ] || continue
    n=$((n + 1))
    inf="${count_list[n-1]:-0}"
    [[ "$inf" =~ ^[0-9]+$ ]] || inf=0
    [ "$c" = "$class" ] || continue
    capnum=""
    [[ "$cap" =~ ^([0-9]+) ]] && capnum="${BASH_REMATCH[1]}"
    [ -n "$capnum" ] || capnum=0
    if [ "$inf" -lt "$capnum" ]; then
      printf '%s\n' "$alias"
      return 0
    fi
  done <<< "$tsv"

  echo "resources_pick: no host of class '$class' with in-flight count below cap (file: $file)" >&2
  return 1
}
