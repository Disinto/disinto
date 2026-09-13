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
# Llama slot lease (#1320, AD-002): an optional `## llama` section is the
# machine-readable lease of the llama-server slots — under --kv-unified the
# KV pool is shared, so the slots are a budget, not per-box capacity:
#
#   ## llama
#   - slots: 4
#   - holder: nomad-box 2
#   - holder: selenocyte-box 1
#
#   resources_llama_slots <file>
#     The integer `slots:` count; exit 1 when the file lacks a `## llama`
#     section.
#   resources_llama_held <file>
#     Sum of the trailing holder counts (0 when there are no holder lines —
#     a missing section is 0, not an error).
#   resources_llama_free <file>
#     slots minus held; exit 1 when the file lacks a `## llama` section.
#
#   A holder/slots value whose count is not a non-negative integer is a hard
#   error: message on stderr, exit 2, no stdout. Files without `## llama`
#   are valid and must not affect resources_hosts / resources_pick. No SSH,
#   no HTTP, no file writes (hire/supervisor wiring is a follow-up).
#
# Return codes: 0 = ok; 1 = file missing, alias unknown, no `## llama`
# section, or no host picked; 2 = usage error (or, for the llama
# functions, a non-integer lease count).

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

# _resources_llama_parsed <file> — emit the `## llama` section (#1320) as
# TSV: one `slots<TAB><n>` line and one `holder<TAB><n>` line per holder
# line (n = the trailing integer; the holder name is the rest of the value
# and is discarded). Only lines inside the `## llama` section (up to the
# next heading of any level, fenced code blocks skipped) are read. Returns
# 1 when the file is missing; a non-integer count is a hard error: message
# on stderr, return 2, no partial stdout.
_resources_llama_parsed() {
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
    { sub(/\r$/, "") }
    /^```/ { incode = !incode; next }
    incode { next }
    /^#/ {
      # `## llama` starts the lease section; any other heading (including
      # `### ` host blocks) ends it.
      inllama = ($0 ~ /^##[ \t]+llama[ \t]*$/) ? 1 : 0
      next
    }
    inllama && /^[ \t]*-[ \t]+[A-Za-z0-9_]+:/ {
      line = $0
      field = line
      sub(/^[ \t]*-[ \t]+/, "", field)
      sub(/:.*$/, "", field)
      value = line
      sub(/^[ \t]*-[ \t]+[^:]*:[ \t]*/, "", value)
      value = trim(value)
      if (field == "slots") {
        if (value !~ /^[0-9]+$/) {
          printf "_resources_llama_parsed: non-integer slots count: %s (line %d)\n", value, FNR > "/dev/stderr"
          exit 2
        }
        print "slots\t" value
      } else if (field == "holder") {
        n = split(value, parts, /[ \t]+/)
        count = parts[n]
        if (count !~ /^[0-9]+$/) {
          printf "_resources_llama_parsed: non-integer holder count: %s (line %d)\n", value, FNR > "/dev/stderr"
          exit 2
        }
        print "holder\t" count
      }
    }
  ' "$file"
}

# resources_llama_slots <file> — print the integer slots count from the
# `## llama` section. 0 = ok; 1 = file missing or no `## llama` section;
# 2 = usage error or non-integer count.
resources_llama_slots() {
  local file="${1:-}" rows v
  if [ -z "$file" ]; then
    echo "usage: resources_llama_slots <file>" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "resources_llama_slots: file not found: $file" >&2
    return 1
  fi
  rows="$(_resources_llama_parsed "$file")" || return 2
  v="$(awk -F'\t' '$1 == "slots" { s = $2 } END { if (s != "") print s }' <<< "$rows")"
  if [ -z "$v" ]; then
    echo "resources_llama_slots: no '## llama' section (or no slots line) in $file" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

# resources_llama_held <file> — print the sum of the trailing holder
# counts. 0 = ok (0 when there are no holder lines, including when the
# section is missing); 1 = file missing; 2 = usage error or non-integer
# count.
resources_llama_held() {
  local file="${1:-}" rows sum
  if [ -z "$file" ]; then
    echo "usage: resources_llama_held <file>" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "resources_llama_held: file not found: $file" >&2
    return 1
  fi
  rows="$(_resources_llama_parsed "$file")" || return 2
  sum="$(awk -F'\t' '$1 == "holder" { s += $2 } END { print s + 0 }' <<< "$rows")"
  printf '%s\n' "$sum"
}

# resources_llama_free <file> — print slots minus held. 0 = ok;
# 1 = file missing or no `## llama` section; 2 = usage error or
# non-integer count.
resources_llama_free() {
  local file="${1:-}" rows slots held
  if [ -z "$file" ]; then
    echo "usage: resources_llama_free <file>" >&2
    return 2
  fi
  if [ ! -f "$file" ]; then
    echo "resources_llama_free: file not found: $file" >&2
    return 1
  fi
  rows="$(_resources_llama_parsed "$file")" || return 2
  slots="$(awk -F'\t' '$1 == "slots" { s = $2 } END { if (s != "") print s }' <<< "$rows")"
  if [ -z "$slots" ]; then
    echo "resources_llama_free: no '## llama' section (or no slots line) in $file" >&2
    return 1
  fi
  held="$(awk -F'\t' '$1 == "holder" { s += $2 } END { print s + 0 }' <<< "$rows")"
  printf '%s\n' $((slots - held))
}
