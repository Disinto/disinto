#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1356.sh
#
# Issue #1356: oak/pack.example.toml adds the n_open (forge_open),
# n_backlog (forge_label "backlog") and edge_ok (http_ok) features so the
# oak state vector carries backlog size and edge health, not just
# disk / inbound / vault_in_flight.
#
# This test is read-only: it parses the example pack from the checkout
# (python3 -c tomllib, same pattern as oak/sense.sh) and runs oak/sense.sh
# once against it (sense.sh GETs only — no network writes, no state).
#
# Verifies:
#   1. n_open, n_backlog, edge_ok are declared with the exact rule/bins/
#      label/url the issue specifies, and the pre-existing disk / inbound /
#      vault features are kept.
#   2. No `kind` key anywhere in the pack.
#   3. oak/sense.sh on the example pack still prints one line of JSON whose
#      key contains `|` (the reused state key is a real multi-part key).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd python3 jq bash

PACK="$REPO_ROOT/oak/pack.example.toml"
ac_assert_file "$PACK" "oak/pack.example.toml must exist"

FEATS="$(python3 -c '
import json, sys, tomllib
print(json.dumps(tomllib.load(open(sys.argv[1], "rb")).get("features", {})))
' "$PACK")"

# ── 1. the three new features, exactly as specified ─────────────────────────
ac_log "checking n_open is forge_open with bins [1, 10]"
ac_assert_jq '.n_open | .rule == "forge_open" and .bins == [1, 10]' \
  "$FEATS" "n_open must be rule=forge_open bins=[1,10]"

ac_log "checking n_backlog is forge_label/backlog with bins [1, 10]"
ac_assert_jq '.n_backlog | .rule == "forge_label"
  and .label == "backlog" and .bins == [1, 10]' \
  "$FEATS" "n_backlog must be rule=forge_label label=backlog bins=[1,10]"

ac_log "checking edge_ok is http_ok against the edge root"
ac_assert_jq '.edge_ok | .rule == "http_ok"
  and .url == "http://127.0.0.1:80/"' \
  "$FEATS" "edge_ok must be rule=http_ok url=http://127.0.0.1:80/"

# ── the pre-existing features are kept ──────────────────────────────────────
ac_log "checking disk / inbound / vault features are kept"
ac_assert_jq '.disk_free_gb | .rule == "df_gb" and .bins == [5, 20]' \
  "$FEATS" "disk_free_gb must stay df_gb with bins [5,20]"
ac_assert_jq '.inbound_present | .rule == "present"' \
  "$FEATS" "inbound_present must stay rule=present"
ac_assert_jq '.vault_in_flight | .rule == "cmd_running"' \
  "$FEATS" "vault_in_flight must stay rule=cmd_running"

# ── 2. no `kind` key anywhere in the pack ───────────────────────────────────
TOP="$(python3 -c '
import json, sys, tomllib
print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))
' "$PACK")"
ac_assert_jq '([.. | objects | has("kind")] | any) | not' "$TOP" \
  "pack must not carry a kind key"

# ── 3. sense.sh still prints one line of JSON with a multi-part key ─────────
ac_log "running oak/sense.sh against the example pack"
OUT="$(bash "$REPO_ROOT/oak/sense.sh" "$PACK" 2>/dev/null)" \
  || ac_fail "oak/sense.sh exited non-zero on the example pack"
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 1 ] \
  || ac_fail "sense.sh output is not exactly one line"
ac_assert_jq 'type == "object" and has("x") and has("key")' "$OUT" \
  "sense.sh output must be a JSON object with x and key"
ac_assert_jq '.key | test("\\|")' "$OUT" \
  "the example pack key must contain | (got: $(jq -r '.key' <<<"$OUT"))"

ac_pass
