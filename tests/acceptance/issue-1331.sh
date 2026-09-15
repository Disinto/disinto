#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1331.sh — oak/sense.sh + oak/pack.example.toml
#
# Issue #1331 (oak tick-learner sprint): the sensor is a program that reads a
# pack every tick:
#   oak/sense.sh PACK.toml  →  one line: {"x":{...},"key":"..."}
#
# Verifies, against the repo checkout's oak/sense.sh (run against private
# temp files — no live state is touched):
#   1. present: missing file → x=0; existing file → x=1
#   2. integer_file garbage → key omitted from x and from key
#   3. bins [5,20] map 12 → 1
#   4. pack.example.toml has no `kind` and lists idle plus the eight organ
#      actions (idle's script is empty)
#   5. example pack: x.disk_free_gb is a non-negative integer (no live df
#      bin assertion)
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
ac_require_cmd python3

SENSE="$REPO_ROOT/oak/sense.sh"
PACK_EX="$REPO_ROOT/oak/pack.example.toml"
ac_assert_file "$SENSE" "oak/sense.sh must exist in the checkout"
ac_assert_file "$PACK_EX" "oak/pack.example.toml must exist in the checkout"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
cd "$TMPD"

# ── 1. present: missing file → 0, existing file → 1 ────────────────────────
ac_log "present: missing file is 0, existing file is 1"
touch here
cat >"$TMPD/pack.toml" <<'EOF'
[features.gone]
rule = "present"
path = "missing-file"

[features.here]
rule = "present"
path = "here"
EOF

out="$(env -u OPS_REPO_ROOT bash "$SENSE" "$TMPD/pack.toml")"
[ "$(jq -r '.x.gone' <<<"$out")" = "0" ] || ac_fail "present: missing file must be x=0"
[ "$(jq -r '.x.here' <<<"$out")" = "1" ] || ac_fail "present: existing file must be x=1"
[ "$(jq -r '.key' <<<"$out")" = "0|1" ] \
  || ac_fail "key must join bits sorted by name (gone|here → 0|1), got: $(jq -r '.key' <<<"$out")"

# ── 2+3. integer_file: garbage omitted, bins [5,20] map 12 → 1 ─────────────
ac_log "integer_file: garbage omitted from x and key; bins [5,20] map 12 → 1"
printf 'not a number\n' >bad
printf '12\n' >cnt
cat >"$TMPD/pack2.toml" <<'EOF'
[features.bad]
rule = "integer_file"
path = "bad"
bins = [5, 20]

[features.cnt]
rule = "integer_file"
path = "cnt"
bins = [5, 20]
EOF

out="$(env -u OPS_REPO_ROOT bash "$SENSE" "$TMPD/pack2.toml")"
[ "$(jq '.x | has("bad")' <<<"$out")" = "false" ] \
  || ac_fail "integer_file with garbage content must be omitted from x"
[ "$(jq '.x | has("cnt")' <<<"$out")" = "true" ] \
  || ac_fail "integer_file with integer content must be present in x"
[ "$(jq -r '.x.cnt' <<<"$out")" = "12" ] \
  || ac_fail "x.cnt must be the raw integer 12, got: $(jq -r '.x.cnt' <<<"$out")"
[ "$(jq -r '.key' <<<"$out")" = "1" ] \
  || ac_fail "key must carry only cnt's bin index (12 → 1), got: $(jq -r '.key' <<<"$out")"

# ── 4. pack.example.toml: no kind, idle plus the eight organ actions ───────
ac_log "pack.example.toml: no kind, idle plus the eight organ actions"
if ! python3 - "$PACK_EX" <<'PYEOF'
import sys, tomllib

with open(sys.argv[1], "rb") as f:
    cfg = tomllib.load(f)

assert "kind" not in cfg, "pack.example.toml must not carry a kind"
want = {
    "idle", "review-poll", "dev-poll", "gardener-step",
    "architect-run", "planner-run", "predictor-run",
    "supervisor-run", "dispatch",
}
actions = cfg.get("actions", {})
missing = want - set(actions)
assert not missing, f"pack.example.toml missing actions: {sorted(missing)}"
assert actions["idle"].get("script", "") == "", "idle action must have an empty script"
PYEOF
then
  ac_fail "pack.example.toml: kind present, actions incomplete, or idle script not empty (see stderr)"
fi

# ── 5. example pack: x.disk_free_gb is a non-negative integer ──────────────
ac_log "example pack: x.disk_free_gb is a non-negative integer"
out="$(bash "$SENSE" "$PACK_EX")"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] \
  || ac_fail "oak/sense.sh stdout must be exactly one line, got: $out"
jq -e 'type == "object" and has("x") and has("key")' >/dev/null <<<"$out" \
  || ac_fail "output must be one JSON object {\"x\":...,\"key\":...}: $out"
jq -e '.x.disk_free_gb | (type == "number") and (. >= 0)' >/dev/null <<<"$out" \
  || ac_fail "x.disk_free_gb must be a non-negative integer, got: $out"
key="$(jq -r '.key' <<<"$out")"
# #1356 added edge_ok (http_ok bit) to the example pack; n_open/n_backlog
# appear in the key only when the forge API is set (FORGE_API/FORGE_TOKEN).
if jq -e '.x | has("n_open")' >/dev/null <<<"$out"; then
  re='^[0-2]\|[01]\|[01]\|[0-2]\|[0-2]\|[01]$'
else
  re='^[0-2]\|[01]\|[01]\|[01]$'
fi
[[ "$key" =~ $re ]] \
  || ac_fail "example-pack key must be df_bin|edge_bit|inbound_bit(|n_backlog_bin|n_open_bin)|flight_bit (sorted by name), got: $key"

echo PASS
