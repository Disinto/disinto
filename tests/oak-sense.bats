#!/usr/bin/env bats
# =============================================================================
# tests/oak-sense.bats — unit tests for oak/sense.sh (#1331)
#
# One tick of the oak sensor: pack TOML → one line of JSON
#   {"x":{...},"key":"..."}
#   present       1 if the path exists (relative → $OPS_REPO_ROOT or cwd),
#                 else 0
#   integer_file  integer contents; missing / not an integer → key omitted
#   bins [5,20]   value <5 → 0, <20 → 1, else 2 (the key carries the bin
#                 index; x carries the raw value)
#   df_gb         with the example pack, x.disk_free_gb is a non-negative
#                 integer (no live df bin assertion)
# forge_* are omitted in these tests (no token), so the example pack's
# n_open/n_backlog are absent from x and from the key.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SENSE="$ROOT/oak/sense.sh"
  PACK="$BATS_TEST_TMPDIR/pack.toml"
  unset OPS_REPO_ROOT FORGE_API FORGE_TOKEN
  cd "$BATS_TEST_TMPDIR"
}

# run_sense <pack> — run oak/sense.sh, capture stdout only (diagnostics go
# to stderr and must not pollute the one-line JSON object).
run_sense() {
  bash "$SENSE" "$1" 2>/dev/null
}

# --- present ---------------------------------------------------------------

@test "present: missing file is 0, existing file is 1" {
  touch here
  cat >"$PACK" <<'EOF'
[features.gone]
rule = "present"
path = "missing-file"

[features.here]
rule = "present"
path = "here"
EOF
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.x.gone' <<<"$output")" = "0" ]
  [ "$(jq -r '.x.here' <<<"$output")" = "1" ]
  # key: features sorted by name (gone, here), joined with |
  [ "$(jq -r '.key' <<<"$output")" = "0|1" ]
}

@test "present: relative path resolves against OPS_REPO_ROOT when set" {
  mkdir -p ops/inbound
  touch ops/inbound/child_registered
  cat >"$PACK" <<'EOF'
[features.inbound_present]
rule = "present"
path = "inbound/child_registered"
EOF
  local out
  out="$(OPS_REPO_ROOT="$BATS_TEST_TMPDIR/ops" bash "$SENSE" "$PACK" 2>/dev/null)"
  [ "$(jq -r '.x.inbound_present' <<<"$out")" = "1" ]
  [ "$(jq -r '.key' <<<"$out")" = "1" ]
  # and without OPS_REPO_ROOT the same relative path resolves against the
  # cwd, where it does not exist
  out="$(bash "$SENSE" "$PACK" 2>/dev/null)"
  [ "$(jq -r '.x.inbound_present' <<<"$out")" = "0" ]
}

# --- integer_file ----------------------------------------------------------

@test "integer_file: garbage content is omitted from x and from key" {
  touch here
  printf 'not a number\n' >bad
  cat >"$PACK" <<'EOF'
[features.bad]
rule = "integer_file"
path = "bad"
bins = [5, 20]

[features.here]
rule = "present"
path = "here"
EOF
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  [ "$(jq '.x | has("bad")' <<<"$output")" = "false" ]
  # the key carries only the feature that produced a value (here → 1)
  [ "$(jq -r '.key' <<<"$output")" = "1" ]
}

@test "integer_file: missing file is omitted from x and from key" {
  cat >"$PACK" <<'EOF'
[features.missing]
rule = "integer_file"
path = "no-such-file"
bins = [5, 20]
EOF
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.x' <<<"$output")" = "{}" ]
  [ "$(jq -r '.key' <<<"$output")" = "" ]
}

# --- bins -------------------------------------------------------------------

@test "bins [5,20]: 12 → 1, 4 → 0, 20 → 2" {
  printf '12\n' >f12
  printf '4\n' >f4
  printf '20\n' >f20
  cat >"$PACK" <<'EOF'
[features.f12]
rule = "integer_file"
path = "f12"
bins = [5, 20]

[features.f4]
rule = "integer_file"
path = "f4"
bins = [5, 20]

[features.f20]
rule = "integer_file"
path = "f20"
bins = [5, 20]
EOF
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  # x carries the raw values
  [ "$(jq -r '.x.f12' <<<"$output")" = "12" ]
  [ "$(jq -r '.x.f4' <<<"$output")" = "4" ]
  [ "$(jq -r '.x.f20' <<<"$output")" = "20" ]
  # key: sorted by name (f12, f20, f4), bin indices joined with |
  [ "$(jq -r '.key' <<<"$output")" = "1|2|0" ]
}

@test "count feature without bins: stderr warning, feature omitted" {
  printf '12\n' >cnt
  cat >"$PACK" <<'EOF'
[features.cnt]
rule = "integer_file"
path = "cnt"
EOF
  local err
  err="$(bash "$SENSE" "$PACK" 2>&1 >/dev/null)"
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.x' <<<"$output")" = "{}" ]
  [ "$(jq -r '.key' <<<"$output")" = "" ]
  [[ "$err" == *no*bins* ]]
}

# --- unknown rule -----------------------------------------------------------

@test "unknown rule: feature omitted, no crash" {
  cat >"$PACK" <<'EOF'
[features.nope]
rule = "vibes"
path = "x"
EOF
  run run_sense "$PACK"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.x' <<<"$output")" = "{}" ]
  [ "$(jq -r '.key' <<<"$output")" = "" ]
}

# --- example pack -----------------------------------------------------------

@test "example pack: one line of JSON, x.disk_free_gb is a non-negative integer" {
  local out
  run run_sense "$ROOT/oak/pack.example.toml"
  out="$output"
  [ "$status" -eq 0 ]
  # stdout: exactly one line, one JSON object with x and key
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]
  run jq -e 'type == "object" and has("x") and has("key")' <<<"$out"
  [ "$status" -eq 0 ]
  # the example pack's df_gb sensor reads a non-negative integer (no live
  # bin assertion — free space is environment-dependent)
  run jq -e '.x.disk_free_gb | (type == "number") and (. >= 0)' <<<"$out"
  [ "$status" -eq 0 ]
  # the bit sensors are always present as 0/1 (the http_ok bit does not
  # require the edge to answer)
  run jq -e '.x.edge_ok | (. == 0 or . == 1)' <<<"$out"
  [ "$status" -eq 0 ]
  run jq -e '.x.inbound_present | (. == 0 or . == 1)' <<<"$out"
  [ "$status" -eq 0 ]
  run jq -e '.x.vault_in_flight | (. == 0 or . == 1)' <<<"$out"
  [ "$status" -eq 0 ]
  # forge_* are omitted without a token, so the key has four parts:
  # disk_free_gb | edge_ok | inbound_present | vault_in_flight (sorted)
  run jq -e '(.x | has("n_open") | not) and (.x | has("n_backlog") | not)' \
    <<<"$out"
  [ "$status" -eq 0 ]
  local key re
  key="$(jq -r '.key' <<<"$out")"
  re='^[0-2]\|[01]\|[01]\|[01]$'
  [[ "$key" =~ $re ]]
}

@test "example pack: n_open, n_backlog, edge_ok are declared for #1356" {
  local feats
  feats="$(python3 -c '
import json, sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
print(json.dumps(cfg.get("features", {})))
' "$ROOT/oak/pack.example.toml")"
  run jq -e '.n_open | .rule == "forge_open" and .bins == [1, 10]' <<<"$feats"
  [ "$status" -eq 0 ]
  run jq -e '.n_backlog | .rule == "forge_label" and .label == "backlog" and .bins == [1, 10]' <<<"$feats"
  [ "$status" -eq 0 ]
  run jq -e '.edge_ok | .rule == "http_ok" and .url == "http://127.0.0.1:80/"' <<<"$feats"
  [ "$status" -eq 0 ]
  # no `kind` key anywhere in the pack
  local top
  top="$(python3 -c '
import json, sys, tomllib
print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))
' "$ROOT/oak/pack.example.toml")"
  run jq -e '([.. | objects | has("kind")] | any) | not' <<<"$top"
  [ "$status" -eq 0 ]
}

# --- usage -------------------------------------------------------------------

@test "missing pack file fails with a diagnostic on stderr" {
  local err
  if err="$(bash "$SENSE" "$BATS_TEST_TMPDIR/nope.toml" 2>&1 >/dev/null)"; then
    false
  fi
  [[ "$err" == *"pack file not found"* ]]
}

@test "wrong argument count exits 2" {
  run bash "$SENSE"
  [ "$status" -eq 2 ]
}
