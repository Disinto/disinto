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
#   n               number of sample pairs in the group, counting stuck
#                   proposals (tools/tape-stuck.sh, #1648) read at read time
#                   — one failure sample each — in addition to the outcome
#                   pairs
#   promised        mean of the proposals' forecast.p_success (as an
#                   integer percent) over the sample pairs that carry a
#                   numeric one (a stuck sample carries the stuck proposal's
#                   forecast, if any); "-" when no sample pair in the group
#                   carries one (old-tape rows have no forecast, so a whole
#                   group may be "-")
#   actual          share of sample pairs that are successes — i.e. whose
#                   last outcome carries at least one of the loop's own
#                   competence bits true or 1, with stuck samples (tools/
#                   tape-stuck.sh, #1648) always counted as the failure
#                   samples in this share — as an integer percentage
#                   integer percentage. Each loop's competence bits are the
#                   .bits keys named for it in the loops pack
#                   ($CALIBRATION_LOOPS_FILE): either one `loop = "bit"`
#                   assignment (a single bit) or a `loop = ["bit1", "bit2"]`
#                   array of double-quoted names (#1614); a single string stays
#                   valid and means a one-element array. A pair is a sample when
#                   its last outcome carries any listed bit (true/false/1/0) and
#                   is a success when any carried bit is true/1, a failure when
#                   all carried bits are false/0. A loop absent from the pack
#                   has no competence bits and is never a sample (the pack —
#                   not this script — decides which loops are samples and which
#                   bits each carries, #1605).
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
# LAST outcome carries at least one of that loop's competence bits
# (true/false/1/0): a success when any carried bit is true/1, a failure when
# all carried bits are false/0. A loop absent from the pack, or a last
# outcome without any carried bit, is dropped from n, promised, actual, mean
# duration_s, dur_promised, and dur_error — never counted as 0% or a
# zero-duration forecast. In addition, a stuck proposal — a proposal past its
# loop's horizon ($CALIBRATION_STUCK_FILE) whose last outcome carries none of
# the loop's bits, or which has no outcome — is a sample read at read time
# (tools/tape-stuck.sh, #1648) and is always counted as a failure; it carries
# no duration or duration forecast, so only n, promised (via the stuck
# proposal's forecast, when present), and actual see it. Same last-outcome
# pairing and row format as before.
#
# Pure bash + jq. No git, no network, no writes: the tape, the loops pack,
# and the stuck pack (read via tools/tape-stuck.sh, #1648) are only read.
# Malformed tape lines (e.g. a torn final line from a crashed writer) are
# skipped with a stderr note, mirroring lib/stats.sh; they never fail the
# report.
#
# Usage:
#   tools/calibration.sh
#
# Environment:
#   TAPE_DIR  tape directory (default /srv/disinto/tape)
#   CALIBRATION_LOOPS_FILE  path to the loop->competence-bits pack (TOML, one
#                           assignment per loop: either a single double-quoted
#                           name, `loop = "bit"`, or a TOML array of one or
#                           more double-quoted names, `loop = ["bit1",
#                           "bit2"]` (#1614); a single string stays valid);
#                           default
#                           ${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/loops.toml.
#   CALIBRATION_STUCK_FILE  path to the stuck pack (flat TOML, one
#                           `loop = <positive-integer-hours>` assignment per
#                           loop, read by tools/tape-stuck.sh, #1648) — the
#                           horizon after which a proposal with no competence
#                           outcome counts as one failure sample; default
#                           ${OPS_REPO_ROOT:-/home/agent/repos/_factory/disinto-ops}/packs/stuck.toml.
#                           A missing file means no horizon is named and
#                           nothing is stuck.
#   CALIBRATION_NOW   ISO-8601 UTC clock (defaults to now) used by tools/
#                     tape-stuck.sh to decide stuckness: a proposal is stuck
#                     when its `t` is more than its loop's horizon hours
#                     before this clock.
#
# Exit codes:
#   0  report printed; a missing or empty tape, or a tape with no sample
#      pairs, prints the header row only
#   1  jq missing, or the loops pack file is missing or unparsable, or the
#      stuck pack is unparsable
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

# Parse the pack (a flat TOML, one assignment per loop) into a JSON object with
# the loop name as its key and the array of competence bits as its value. Each
# value may be either a single double-quoted name (the pre-#1614 form, read as
# a one-element array) or a TOML array of one or more double-quoted names
# (#1614, e.g. `dev = ["merged", "rejected"]`); a single string stays valid.
# Anything else — a missing "=", an invalid key, an unquoted value, or a value
# that is neither a quoted name nor a quoted-name array — is an unparsable
# pack. The parse is done in awk (no extra dependency); a blank line, a comment
# (full-line or inline #), and a line whose key/value do not match the
# documented shape are rejected. Exit 3 on the first bad line.
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
    if (val ~ /^"[^"]*"$/) {
      # a single double-quoted name (the pre-#1614 form): kept valid and read
      # as a one-element array
      v = substr(val, 2, length(val) - 2)
      n++
      entry[n] = "\"" key "\" : [\"" v "\"]"
    } else if (val ~ /^\[.*\]$/) {
      # a TOML array of one or more double-quoted names (#1614): the value is
      # "[name1", "name2", ...]" with the leading "[" and trailing "]" stripped
      inner = substr(val, 2, length(val) - 2)
      nbody = split(inner, parts, ",")
      if (nbody == 0) { print "unparsable line " NR ": " $0; exit 3 }
      for (i = 1; i <= nbody; i++) {
        part = parts[i]
        sub(/^[[:space:]]+/, "", part)
        sub(/[[:space:]]+$/, "", part)
        if (part !~ /^"[^"]*"$/) { print "unparsable line " NR ": " $0; exit 3 }
      }
      n++
      entry[n] = "\"" key "\" : ["
      for (i = 1; i <= nbody; i++) {
        part = parts[i]
        sub(/^[[:space:]]+/, "", part)
        sub(/[[:space:]]+$/, "", part)
        entry[n] = entry[n] part
        if (i < nbody) entry[n] = entry[n] ","
      }
      entry[n] = entry[n] "]"
    } else {
      print "unparsable line " NR ": " $0
      exit 3
    }
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

# Read stuck proposals (#1649): tools/tape-stuck.sh (#1648) lists proposals
# past their loop's horizon with no competence outcome; each is one failure
# sample, read at read time. It takes the parsed loops pack as LOOPS_JSON (so
# it reads the same loop->bits shape we just built) and reads the stuck pack
# from $CALIBRATION_STUCK_FILE and the clock from $CALIBRATION_NOW (documented
# under Environment). A missing stuck pack means no horizon is named and
# nothing is stuck (the tool prints []); an unparsable stuck pack fails the
# whole report, so exit 1 here (see Exit codes).
stuck_json="$(
  "$(dirname "$0")/tape-stuck.sh" "$pack_json"
)" || { echo "calibration: failed to read stuck pack" >&2; exit 1; }

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
jq -R -s -r --argjson loops "$pack_json" --argjson stuck "$stuck_json" '
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
  # LAST outcome carries at least one competence bit of the named loop. The
  # pack names those bits as the array $loops[.loop]; each is looked up in the
  # bits of the pair. A pair is a sample when at least one of its listed bits
  # is carried (true/false/1/0 — only the values the tape writers emit counts);
  # it is a success when any carried bit is true/1 and a failure when all are
  # false/0. A loop absent from the pack, or a last outcome without any carried
  # bit, is never a sample.
  | map({ loop: .loop,
           class: .class,
           promised: .promised,
           est_dvision: .est_dvision,
           competence: (($loops[.loop]) as $bits
                        | if ($bits | type) == "array"
                           then [ $bits[] as $b | .bits[$b] ]
                                 | map(select(. == true or . == false or . == 1 or . == 0))
                           else null end),
           duration: .duration })
  | map(select((.competence | type) == "array" and (.competence | length) > 0))
  # Stuck proposals (tools/tape-stuck.sh, #1648) arrive already in sample
  # shape — competence [false], duration/est_dvision null, signature "stuck"
  # — so appending them (`. + $stuck`) adds one failure sample per stuck
  # proposal without touching any other column. They count in n, pull `actual`
  # below what the outcomes alone give, and contribute nothing to the mean
  # duration or duration-forecast columns.
  | . + $stuck
  | group_by([.loop, .class])
  | map({ loop: .[0].loop,
           class: .[0].class,
           n: length,
           promised: ((map(.promised) | map(select(. != null)))
                      | if length > 0 then ((100 * add / length) | round) else null end),
           mr: (100 * (map(select(.competence | any(. == true or . == 1))) | length)
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
