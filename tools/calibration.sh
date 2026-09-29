#!/usr/bin/env bash
# =============================================================================
# tools/calibration.sh — promised vs actual over the proposal-loop tape (#1393)
#
# Reads $TAPE_DIR/tape.jsonl (default /srv/disinto/tape/tape.jsonl) — the
# append-only tape written by lib/tape.sh (#1389) — and pairs each proposal
# with the outcome it reached: the LAST outcome record (in tape order) whose
# proposal_id matches the proposal's id (records are immutable, so a later
# outcome is the more recent state — e.g. the dev PR's terminal-state
# outcome, #1399, follows the formula session's end-of-session outcome,
# #1391). run/grade records are ignored. An outcome whose proposal_id
# matches no proposal (orphan) is skipped; a proposal without any outcome
# forms no pair.
#
# Pairs are grouped by (loop, class) — both taken from the proposal — after
# dropping non-samples, and summarised as a markdown table on stdout:
#
#   | loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |
#
#   n               number of sample pairs in the group
#   promised        mean of the proposals' forecast.p_success (as an
#                   integer percent) over the sample pairs that carry a
#                   numeric one; "-" when no sample pair in the group
#                   carries one (old-tape rows have no forecast, so a whole
#                   group may be "-")
#   actual          share of sample pairs whose last outcome carries the
#                   loop's own competence bit true or 1, as an integer
#                   percentage. Which .bits key is each loop's competence bit
#                   is named in the loops pack (the file $CALIBRATION_LOOPS_FILE
#                   points at) as one `loop = "bit"` assignment per loop: the
#                   bit is the .bits key to look up. A loop absent from the
#                   pack has no competence bit and is never a sample (the
#                   pack — not this script — decides which loops are samples and
#                   which bit each carries, #1605).
#   error           |promised - actual| in percentage points when promised
#                   is present; "-" otherwise
#   mean duration_s mean of the sample pairs' outcome numbers.duration_s over
#                   the pairs that carry one (missing ones are skipped, never
#                   counted as zero); "-" when no sample pair in the group
#                   carries a duration
#   dur_promised    mean of the proposals' forecast.est_dvision (seconds) over
#                   the sample pairs whose value is numeric and greater than 0,
#                   one decimal (same style as mean duration_s); "-" when no
#                   sample pair in the group carries a positive one (0 is the
#                   pre-#1525 stub and missing is not a forecast, so neither
#                   is counted)
#   dur_error       |dur_promised - mean duration_s|, one decimal, when both
#                   are present; "-" otherwise
#
# A pair is a sample only when the loop is named in the loops pack AND the
# LAST outcome carries that loop's competence bit (true/false/1/0): true/1
# is a success, false/0 a failure. A loop absent from the pack, or a last
# outcome without the bit, is dropped from n, promised, actual, mean
# duration_s, dur_promised, and dur_error — never counted as 0% or a
# zero-duration forecast. Same last-outcome pairing and row format as before.
#
# Pure bash + jq. No git, no network, no writes: the tape and the loops pack
# are only read. Malformed tape lines (e.g. a torn final line from a crashed
# writer) are skipped with a stderr note, mirroring lib/stats.sh; they never
# fail the report.
#
# Usage:
#   tools/calibration.sh
#
# Environment:
#   TAPE_DIR  tape directory (default /srv/disinto/tape)
#   CALIBRATION_LOOPS_FILE  path to the loop->competence-bit pack (TOML, one
#                           `loop = "bit"` assignment per loop, double-quoted
#                           value); default
#                           ${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml.
#
# Exit codes:
#   0  report printed; a missing or empty tape, or a tape with no sample
#      pairs, prints the header row only
#   1  jq missing, or the loops pack file is missing or unparsable
# =============================================================================
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "calibration: required tool missing: jq" >&2; exit 1; }

TAPE_DIR="${TAPE_DIR:-/srv/disinto/tape}"
TAPE_FILE="${TAPE_DIR}/tape.jsonl"
# The loop->competence-bit pack. $CALIBRATION_LOOPS_FILE is the test seam; the
# default is the ops repo's packs/loops.toml (shipped separately, disinto-ops
# issue #1605).
LOOPS_FILE="${CALIBRATION_LOOPS_FILE:-${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml}"

echo '| loop | class | n | promised | actual | error | mean duration_s | dur_promised | dur_error |'
echo '|---|---|---|---|---|---|---|---|---|'

# Fail closed before touching the tape: the loop->competence-bit map now lives
# in the pack, so without a readable pack there is no sample to summarise and
# there is no fallback to a hardcoded loop->bit map (removing that map is the
# point of #1605).
[ -f "$LOOPS_FILE" ] || { echo "calibration: loops pack file missing: $LOOPS_FILE" >&2; exit 1; }

# Parse the pack (a flat TOML, one `loop = "bit"` assignment per loop) into a
# JSON object with the pack as its key and the bit name as its value. Double-
# quoted values only (the documented pack format); anything else — a missing
# "=", an invalid key, or a non-double-quoted value — is an unparsable pack.
# The parse is done in awk (no extra dependency); a blank line, a comment (
# full-line or inline #), and a line whose key/value do not match the documented
# shape are rejected. Exit 3 on the first bad line.
rc=0
pack_json="$(awk '
  BEGIN { n = 0 }
  {
    l = $0
    sub(/[[:space:]]*#.*$/, "", l)   # strip inline comment
    sub(/^[[:space:]]+/, "", l)
    sub(/[[:space:]]+$/, "", l)
    if (l == "") next                # blank line
    eqpos = index(l, "=")
    if (eqpos <= 1) { print "unparsable line " NR ": no assignment"; exit 3 }
    key = substr(l, 1, eqpos - 1)
    val = substr(l, eqpos + 1)
    sub(/^[[:space:]]+/, "", key)
    sub(/[[:space:]]+$/, "", key)
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)
    if (key !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) { print "unparsable line " NR ": " $0; exit 3 }
    if (val !~ /^"[^"]*"$/) { print "unparsable line " NR ": " $0; exit 3 }
    val = substr(val, 2, length(val) - 2)
    n++
    entry[n] = "\"" key "\" : \"" val "\""
  }
  END {
    if (n == 0) { print "{}" }
    else {
      out = "{"
      for (i = 1; i <= n; i++) {
        out = out entry[i]
        if (i < n) out = out ","
      }
      out = out "}"
      print out
    }
  }
' "$LOOPS_FILE")" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "calibration: failed to parse loops pack $LOOPS_FILE" >&2
  exit 1
fi

[ -f "$TAPE_FILE" ] || exit 0
[ -s "$TAPE_FILE" ] || exit 0

# Count all lines and the parseable records; the difference is the number of
# malformed lines to skip (a torn final line from a crashed writer),
# mirroring lib/stats.sh.
total_lines=$(grep -c '' "$TAPE_FILE" || true)
valid_lines=$(jq -R -c 'fromjson? | select(type == "object")' < "$TAPE_FILE" | grep -c '' || true)
total_lines="${total_lines:-0}"
valid_lines="${valid_lines:-0}"
skipped=$(( total_lines - valid_lines ))
[ "$skipped" -ge 0 ] || skipped=0
[ "$skipped" -eq 0 ] || echo "calibration: skipped ${skipped} malformed line(s) in ${TAPE_FILE}" >&2

# One tab-separated row per (loop, class) sample group:
# loop <tab> class <tab> n <tab> promised (integer %, or the literal
# "-") <tab> actual (integer %) <tab> mean duration_s (the literal
# "NA" when no pair in the group carries one) <tab> est duration_s (the
# literal "NA" when no sample pair in the group carries a numeric
# est_dvision greater than 0). The reader derives error =
# |promised - actual| (or "-") and dur_error = |est duration_s - mean
# duration_s| (or "-") from the same values.
jq -R -s -r --argjson loops "$pack_json" '
  [ split("\n")[]
    | (try fromjson catch null)
    | select(type == "object") ] as $recs
  | ($recs | map(select(.type == "proposal"
                  and ((.id | type) == "string")
                  and ((.loop | type) == "string")
                  and ((.class | type) == "string")))
      | map({ key: .id, value: { loop: .loop, class: .class,
                                  promised: (.forecast.p_success
                                             | if type == "number" then . else null end),
                                  est_dvision: (.forecast.est_dvision
                                               | if type == "number" then . else null end) } })
      | from_entries) as $props
  | [ $recs[]
        | select(.type == "outcome"
                 and ((.proposal_id | type) == "string")
                 and ($props[.proposal_id] != null)) ]
  | group_by(.proposal_id)
  | map(last)
  | map({ loop: $props[.proposal_id].loop,
           class: $props[.proposal_id].class,
           promised: $props[.proposal_id].promised,
           est_dvision: $props[.proposal_id].est_dvision,
           bits: (.bits | if type == "object" then . else {} end),
           duration: (.numbers.duration_s
                      | if type == "number" then . else null end) })
  # A pair is a sample only when the loop is named in the loops pack AND the
  # LAST outcome carries the competence bit of that loop. The pack names the
  # bit as $loops[.loop]; it is looked up in the bits of the pair. true/1 is a
  # false/0 a failure; only a well-formed bit (true/false/1/0, the values the
  # tape writers emit) counts as carried. A loop absent from the pack, or a
  # last outcome without the bit, is never a sample.
  | map({ loop: .loop,
           class: .class,
           promised: .promised,
           est_dvision: .est_dvision,
           competence: (($loops[.loop]) as $bit
                        | if ($bit | type) == "string" then .bits[$bit]
                          else null end),
           duration: .duration })
  | map(select(.competence == true or .competence == false
                or .competence == 1 or .competence == 0))
  | group_by([.loop, .class])
  | map({ loop: .[0].loop,
           class: .[0].class,
           n: length,
           promised: ((map(.promised) | map(select(. != null)))
                      | if length > 0 then ((100 * add / length) | round) else null end),
           mr: (100 * (map(select(.competence == true or .competence == 1)) | length)
                 / length | round),
           md: ((map(.duration) | map(select(. != null)))
                | if length > 0 then add / length else null end),
           df: ((map(.est_dvision) | map(select(. != null)) | map(select(. > 0)))
                | if length > 0 then add / length else null end) })
  | .[]
  | "\(.loop)\t\(.class)\t\(.n)\t\(if .promised == null then "-" else (.promised | tostring) end)\t\(.mr)\t\(if .md == null then "NA" else (.md | tostring) end)\t\(if .df == null then "NA" else (.df | tostring) end)"
' "$TAPE_FILE" |
while IFS=$'\t' read -r lp cl n promised actual md df; do
  if [ "$md" = "NA" ]; then
    mean="-"
  else
    mean="$(printf "%.1f" "$md")"
  fi
  if [ "$promised" = "-" ]; then
    p="-"
    e="-"
  else
    p="${promised}%"
    d=$(( promised - actual ))
    [ "$d" -lt 0 ] && d=$(( -d ))
    e="$d"
  fi
  if [ "$df" = "NA" ]; then
    durp="-"
    dure="-"
  else
    durp="$(printf "%.1f" "$df")"
    if [ "$md" = "NA" ]; then
      dure="-"
    else
      dure="$(awk -v a="$durp" -v b="$mean" \
        'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.1f", d }')"
    fi
  fi
  printf '| %s | %s | %s | %s | %s%% | %s | %s | %s | %s |\n' \
    "$lp" "$cl" "$n" "$p" "$actual" "$e" "$mean" "$durp" "$dure"
done
