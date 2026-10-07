#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1914.sh
#
# Issue #1914: parse_subissue_entries keeps blank lines inside a sub-issue
# body, strips every trailing newline, and escapes " and \ in titles and
# bodies so the filed JSON stays valid. A literal trailing \n is kept.
#
# Hermetic: no network, no forge. The parser is the copy ac_extract_fn
# returns.
#
# Acceptance: `bash tests/acceptance/issue-1914.sh` exits 0 and calls ac_pass.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tests/lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq
ac_assert_file "$REPO_ROOT/lib/sprint-filer.sh" "lib/sprint-filer.sh is missing"

FN="$(ac_extract_fn parse_subissue_entries "$REPO_ROOT/lib/sprint-filer.sh")"
[ -n "$FN" ] || ac_fail "ac_extract_fn did not return parse_subissue_entries"
eval "$FN"

# A following entry keeps trailing blank lines inside the block: command
# substitution in parse_subissue_entries would otherwise eat them.
parse_entries() {
  parse_subissue_entries <<'EOF'
- id: blanks
  title: "keep blanks"
  labels: [backlog]
  depends_on: []
  body: |
    paragraph one

    paragraph two

    ## Problem
    The heading stays separate.
- id: quoted
  title: "fix: "quoted" \ path"
  labels: [backlog]
  depends_on: []
  body: |
    one line
- id: trailing
  title: "no trailing newline"
  labels: [backlog]
  depends_on: []
  body: |
    first

    second


- id: stopper
  title: "stops the block"
  labels: [backlog]
  depends_on: []
  body: |
    done
- id: escapes
  title: "body escapes"
  labels: [backlog]
  depends_on: []
  body: |
    path is C:\temp and a "quote"
- id: slashn
  title: "literal slash-n"
  labels: [backlog]
  depends_on: []
  body: |
    ends with slash-n \n
EOF
}

ac_log "AC1: blank lines between paragraphs and before ## Problem are kept"
json="$(parse_entries)"
printf '%s\n' "$json" | jq -e . >/dev/null \
  || ac_fail "parse_subissue_entries must emit JSON jq can parse"
expected_blanks=$'paragraph one\n\nparagraph two\n\n## Problem\nThe heading stays separate.'
got_blanks="$(printf '%s\n' "$json" | jq -er '.[0].body')"
ac_assert_eq "$got_blanks" "$expected_blanks" \
  "body must keep both blank lines (got $(printf '%s' "$got_blanks" | jq -Rs .))"
ac_log "AC1 OK"

ac_log "AC2: a title with quotes and a backslash is valid JSON"
want_title='fix: "quoted" \ path'
got_title="$(printf '%s\n' "$json" | jq -er '.[1].title')"
ac_assert_eq "$got_title" "$want_title" \
  "title must equal fix: \"quoted\" \\ path (got $(printf '%s' "$got_title" | jq -Rs .))"
ac_log "AC2 OK"

ac_log "AC3: a body ending in blank lines has no trailing newline"
got_trailing="$(printf '%s\n' "$json" | jq -er '.[2].body')"
expected_trailing=$'first\n\nsecond'
ac_assert_eq "$got_trailing" "$expected_trailing" \
  "trailing blank lines must be stripped but the internal one kept (got $(printf '%s' "$got_trailing" | jq -Rs .))"
case "$got_trailing" in
  *$'\n') ac_fail "parsed body must not end with a newline" ;;
esac
ac_log "AC3 OK"

ac_log "AC4: a body backslash and a quote round-trip"
want_escapes='path is C:\temp and a "quote"'
got_escapes="$(printf '%s\n' "$json" | jq -er '.[4].body')"
ac_assert_eq "$got_escapes" "$want_escapes" \
  "body must keep C:\\temp and the quote (got $(printf '%s' "$got_escapes" | jq -Rs .))"
ac_log "AC4 OK"

ac_log "AC5: a body ending in a literal backslash-n keeps those characters"
want_slashn='ends with slash-n \n'
got_slashn="$(printf '%s\n' "$json" | jq -er '.[5].body')"
ac_assert_eq "$got_slashn" "$want_slashn" \
  "literal trailing backslash-n must be kept (got $(printf '%s' "$got_slashn" | jq -Rs .))"
case "$got_slashn" in
  *$'\n') ac_fail "literal backslash-n must not be a trailing newline" ;;
esac
ac_log "AC5 OK"

ac_pass
