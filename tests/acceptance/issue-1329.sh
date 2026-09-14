#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1329.sh — oak/td.sh tabular SARSA via jq
#
# Issue #1329 (oak tick-learner sprint): one dumb learner update —
# tabular SARSA on a JSON weights table:
#   q  = Q[x_key][a]    // q0 if missing
#   q2 = Q[x2_key][a2]  // q0 if missing
#   Q[x_key][a] = q + alpha * (r + gamma * q2 - q)
#
# Verifies, against the repo checkout's oak/td.sh (run against a private
# temp file — no live state is touched):
#   1. missing weights file is created with empty Q/V objects and q0 1.0
#   2. one update with r=0, q=q2=q0=1 stores Q < 1 (stdout: JSON number)
#   3. a second update on the same key moves Q again
#   4. extra inbound cumulant writes gvf.inbound.V (next value V[x2_key],
#      missing → 0, never q0)
#   5. the write is atomic: no *.tmp file lingers
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash
ac_require_cmd jq

TD="$REPO_ROOT/oak/td.sh"
ac_assert_file "$TD" "oak/td.sh must exist in the checkout"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
W="$TMPD/weights.json"
U="$TMPD/update.json"

# ── 1. missing weights file is created with empty Q/V objects ────────────────
printf '%s' '{"alpha":0.1,"gamma":0.99,"q0":1.0,"x_key":"2|0","a":"idle","r":0,"x2_key":"2|0","a2":"idle"}' >"$U"

ac_log "running first update against a missing weights file"
first="$(bash "$TD" "$W" "$U")"
ac_assert_file "$W" "oak/td.sh must create the missing weights file"
ac_assert_jq '.q0 == 1.0' "$(cat "$W")" \
  "fresh table must default q0 to 1.0"
ac_assert_jq '(.gvf.purpose | has("Q")) and (.gvf.inbound | has("V"))' "$(cat "$W")" \
  "fresh table must have empty purpose.Q and inbound.V objects"
ac_assert_jq '.gvf.inbound.V == {}' "$(cat "$W")" \
  "inbound V must stay empty without an extra cumulant"

# ── 2. one update with r=0, q=q2=q0=1 stores Q < 1 ───────────────────────────
ac_log "checking the new purpose Q value: $first"
[ "$(printf '%s\n' "$first" | wc -l)" -eq 1 ] || ac_fail "stdout must be exactly one line"
jq -e 'type == "number"' <<<"$first" >/dev/null \
  || ac_fail "stdout must be a JSON number, got: $first"
jq -e '(. < 1) and (. > 0.998)' <<<"$first" >/dev/null \
  || ac_fail "expected 0.998 < Q < 1 with r=0, q=q2=q0=1, got: $first"
[ "$(jq -r '.gvf.purpose.Q["2|0"].idle' "$W")" = "$first" ] \
  || ac_fail "stored Q[x_key][a] must equal the value printed on stdout"

# ── 3. a second update on the same key moves Q again ─────────────────────────
sed 's/"r":0/"r":-1/' "$U" >"$U.neg"
second="$(bash "$TD" "$W" "$U.neg")"
[ "$second" != "$first" ] || ac_fail "second update must move Q again"
jq -e --argjson a "$first" --argjson b "$second" '$b < $a' >/dev/null \
  || ac_fail "Q must decrease with r=-1 (got $first -> $second)"

# ── 4. extra inbound cumulant writes gvf.inbound.V ────────────────────────────
sed 's/}$/,"extra":{"inbound":0.5}}/' "$U" >"$U.ex"
bash "$TD" "$W" "$U.ex" >/dev/null
ac_assert_jq '.gvf.inbound.V["2|0"] | (. > 0.049 and . < 0.051)' "$(cat "$W")" \
  "extra inbound=0.5 must store V = 0.1 * (0.5 + 0.99*0) = 0.05"

# missing V[x2_key] → next value 0, never q0
TMPD2="$(mktemp -d)"
trap 'rm -rf "$TMPD" "$TMPD2"' EXIT
W2="$TMPD2/weights.json"
sed 's/"x2_key":"2|0"/"x2_key":"3|1"/; s/}$/,"extra":{"inbound":1}}/' "$U" >"$U.x2"
bash "$TD" "$W2" "$U.x2" >/dev/null
ac_assert_jq '.gvf.inbound.V["2|0"] | (. > 0.099 and . < 0.101)' "$(cat "$W2")" \
  "missing V[x2_key] must default to 0, not q0 (expected 0.1)"

# ── 5. atomic write: no *.tmp lingers ─────────────────────────────────────────
[ ! -f "$W.tmp" ] || ac_fail "oak/td.sh must leave no ${W##*/}.tmp file behind"

echo PASS
