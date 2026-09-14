#!/usr/bin/env bats
# =============================================================================
# tests/oak-td.bats — unit tests for oak/td.sh (#1329)
#
# Tabular SARSA on a JSON weights table, all floats via jq:
#   q  = Q[x_key][a]    // q0 if missing
#   q2 = Q[x2_key][a2]  // q0 if missing
#   Q[x_key][a] = q + alpha * (r + gamma * q2 - q)
# Optional "extra":{"inbound":n} also steps gvf.inbound.V[x_key] with the
# same SARSA rule, cumulant = n, next value = V[x2_key] (missing → 0).
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TD="$ROOT/oak/td.sh"
  W="$BATS_TEST_TMPDIR/weights.json"
  U="$BATS_TEST_TMPDIR/update.json"
  printf '%s' '{"alpha":0.1,"gamma":0.99,"q0":1.0,"x_key":"2|0","a":"idle","r":0,"x2_key":"2|0","a2":"idle"}' >"$U"
}

# run_td <weights-file> <update-file> — run oak/td.sh, capture stdout only
# (diagnostics go to stderr and must not pollute the one-line JSON number).
run_td() {
  bash "$TD" "$1" "$2" 2>/dev/null
}

# --- fresh table -------------------------------------------------------------

@test "missing weights file is created with empty Q/V objects and q0 1.0" {
  [ ! -f "$W" ]
  run run_td "$W" "$U"
  [ "$status" -eq 0 ]
  [ -f "$W" ]
  [ ! -f "$W.tmp" ]
  run jq -e '.q0 == 1.0 and (.gvf.purpose | has("Q")) and (.gvf.inbound | has("V"))' "$W"
  [ "$status" -eq 0 ]
  # no extra key → inbound V must stay empty
  run jq -e '.gvf.inbound.V == {}' "$W"
  [ "$status" -eq 0 ]
}

@test "stdout is one line holding the new purpose Q value as a JSON number" {
  run run_td "$W" "$U"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  run jq -e 'type == "number"' <<<"$output"
  [ "$status" -eq 0 ]
}

# --- SARSA step ---------------------------------------------------------------

@test "one update with r=0, q=q2=q0=1 stores Q < 1" {
  run run_td "$W" "$U"
  [ "$status" -eq 0 ]
  local q="$output"
  run jq -e '(. < 1) and (. > 0.998)' <<<"$q"
  [ "$status" -eq 0 ]
  # the stored value is the value printed on stdout
  [ "$(jq -r '.gvf.purpose.Q["2|0"].idle' "$W")" = "$q" ]
}

@test "second update on the same key moves Q again" {
  run run_td "$W" "$U"
  [ "$status" -eq 0 ]
  first="$output"
  # r = -1 this time
  sed 's/"r":0/"r":-1/' "$U" >"$U.neg"
  run run_td "$W" "$U.neg"
  [ "$status" -eq 0 ]
  local second="$output"
  [ "$second" != "$first" ]
  # Q must have moved down (negative reward)
  # -n: $a/$b only — no input stream (jq >= 1.7 exits 4 on empty stdin)
  run jq -en --argjson a "$first" --argjson b "$second" '$b < $a'
  [ "$status" -eq 0 ]
  # and the file holds the new value
  [ "$(jq -r '.gvf.purpose.Q["2|0"].idle' "$W")" = "$second" ]
}

@test "missing Q entries default to the file q0" {
  echo '{"q0":2.5,"gvf":{"purpose":{"Q":{}},"inbound":{"V":{}}}}' >"$W"
  run run_td "$W" "$U"
  [ "$status" -eq 0 ]
  # q = q2 = 2.5 → 2.5 + 0.1 * (0 + 0.99 * 2.5 - 2.5) = 2.4975
  run jq -e '(. > 2.496 and . < 2.499)' <<<"$output"
  [ "$status" -eq 0 ]
  # the file's own q0 is preserved, not overwritten by the update's q0
  run jq -e '.q0 == 2.5' "$W"
  [ "$status" -eq 0 ]
}

# --- extra inbound GVF --------------------------------------------------------

@test "extra inbound cumulant writes gvf.inbound.V" {
  sed 's/}$/,"extra":{"inbound":0.5}}/' "$U" >"$U.ex"
  run run_td "$W" "$U.ex"
  [ "$status" -eq 0 ]
  # v = v2 = 0 → 0 + 0.1 * (0.5 + 0.99 * 0 - 0) = 0.05
  run jq -e '.gvf.inbound.V["2|0"] | (. > 0.049 and . < 0.051)' "$W"
  [ "$status" -eq 0 ]
}

@test "inbound next value is V[x2_key], missing → 0 (never q0)" {
  # x2_key differs and has no V entry: v2 must be 0, not q0=1.
  sed 's/"x2_key":"2|0"/"x2_key":"3|1"/' "$U" >"$U.x2"
  sed -i 's/}$/,"extra":{"inbound":1}}/' "$U.x2"
  run run_td "$W" "$U.x2"
  [ "$status" -eq 0 ]
  # v = 0 → 0 + 0.1 * (1 + 0.99 * 0 - 0) = 0.1
  run jq -e '.gvf.inbound.V["2|0"] | (. > 0.099 and . < 0.101)' "$W"
  [ "$status" -eq 0 ]
}

# --- error handling ------------------------------------------------------------

@test "missing update file fails with a diagnostic on stderr" {
  local err
  if err="$(bash "$TD" "$W" "$BATS_TEST_TMPDIR/nope.json" 2>&1 >/dev/null)"; then
    false
  fi
  [[ "$err" == *"update file not found"* ]]
}

@test "update with a non-numeric r is rejected" {
  sed 's/"r":0/"r":"zero"/' "$U" >"$U.bad"
  run run_td "$W" "$U.bad"
  [ "$status" -ne 0 ]
  [ ! -f "$W" ]
}
