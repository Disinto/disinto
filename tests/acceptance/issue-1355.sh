#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1355.sh — oak/tick.sh updates extra GVFs from [gvf.*]
#
# Issue #1355 (Oak sprint 2): after sense, every pack [gvf.<name>] other than
# purpose contributes a cumulant to UPDATE.json "extra" (c="r" → the purpose
# Q update, skipped; c="feature:<f>" → x2[<f>] when a number, else 0), and
# oak/td.sh steps gvf.<name>.V for each. So a dry-run tick with
# inbound_present=0 writes a number into gvf.inbound.V[x_key] — the key
# EXISTS (value 0), it is not dropped — while the purpose Q keeps updating,
# and a pack without [gvf.inbound] does not crash.
#
# Verified against the checkout's oak/tick.sh, in private temp dirs with
# OAK_DRY_RUN=1 (no organ is ever started, no live state is touched).
#
# Last stdout line is PASS or FAIL: <reason>.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/oak-fixture.sh"

ac_require_cmd bash jq python3

TICK1355="$REPO_ROOT/oak/tick.sh"
ac_assert_file "$TICK1355" "oak/tick.sh must exist in the checkout"

# env.sh (sourced by tick.sh) hard-requires USER and HOME — safe defaults
# when run outside the factory.
export USER="${USER:-ac1355}"
export HOME="${HOME:-/tmp}"

WORKDIR1355="$(mktemp -d)"
trap 'rm -rf "$WORKDIR1355"' EXIT
cd "$WORKDIR1355"

TICK_ERR="$WORKDIR1355/tick-err.log"

# run_tick1355 <project.toml> — one OAK_DRY_RUN tick; stdout = chosen action.
run_tick1355() {
  env -u AGENT_ROLES -u DISINTO_CONTAINER \
    OAK_DRY_RUN=1 bash "$TICK1355" "$1" 2>"$TICK_ERR"
}

# tick_pair1355 <label> <project.toml> — a boot tick + one learning tick (the
# second carries the SARSA step); FAIL on either tick.
tick_pair1355() {
  local label="$1" proj="$2"
  if ! run_tick1355 "$proj" >/dev/null; then
    ac_oak_tick_fail "$label: boot tick failed" "$TICK_ERR"
  fi
  if ! run_tick1355 "$proj" >/dev/null; then
    ac_oak_tick_fail "$label: learning tick failed" "$TICK_ERR"
  fi
}

# GVF extra for the fixture: purpose (the Q update) + the inbound GVF on
# the present feature inbound_present (absent file → cumulant 0).
GVF_EXTRA_1355='[gvf.purpose]
c = "r"

[gvf.inbound]
c = "feature:inbound_present"

[features.inbound_present]
rule = "present"
path = "inbound/child_registered"'

# ── Fixture A: [gvf.inbound] with inbound_present=0 ──────────────────────────
OPS_A="$WORKDIR1355/ops-a"
REPO_A="$WORKDIR1355/repo-a"
mkdir -p "$REPO_A"
ac_oak_pack "$OPS_A/pack.toml" "$GVF_EXTRA_1355"
ac_oak_project_toml "$WORKDIR1355/project-a.toml" "tick-a" "$REPO_A" "$OPS_A"

ac_log "fixture A: boot + learning tick with inbound_present=0"
tick_pair1355 "fixture A" "$WORKDIR1355/project-a.toml"
W_A="$OPS_A/oak/weights.json"
# features: done=0, here=1, inbound_present=0 → state key "0|1|0"
ac_assert_jq '.gvf.inbound.V | has("0|1|0")' "$(cat "$W_A")" \
  "gvf.inbound.V must have key 0|1|0 after a learning tick (the key must exist)"
ac_assert_jq '.gvf.inbound.V["0|1|0"] | type == "number"' "$(cat "$W_A")" \
  "gvf.inbound.V[0|1|0] must be a JSON number"
ac_assert_jq '.gvf.inbound.V["0|1|0"] == 0' "$(cat "$W_A")" \
  "cumulant 0 with v=v2=0 must leave V at exactly 0"
ac_assert_jq '(.gvf.purpose.Q["0|1|0"]["idle"]) < 1.0' "$(cat "$W_A")" \
  "the purpose Q must still update (SARSA)"

# ── Fixture B: same pack, inbound_present=1 (the file exists) ────────────────
OPS_B="$WORKDIR1355/ops-b"
REPO_B="$WORKDIR1355/repo-b"
mkdir -p "$REPO_B" "$OPS_B/inbound"
touch "$OPS_B/inbound/child_registered"
ac_oak_pack "$OPS_B/pack.toml" "$GVF_EXTRA_1355"
ac_oak_project_toml "$WORKDIR1355/project-b.toml" "tick-b" "$REPO_B" "$OPS_B"

ac_log "fixture B: the same ticks with inbound_present=1"
tick_pair1355 "fixture B" "$WORKDIR1355/project-b.toml"
W_B="$OPS_B/oak/weights.json"
ac_assert_jq '.gvf.inbound.V["0|1|1"] | (. > 0.099 and . < 0.101)' "$(cat "$W_B")" \
  "cumulant 1 with v=v2=0 must move V to ~0.1 (0 + 0.1*(1+0.99*0-0))"

# ── Fixture C: pack without [gvf.inbound] ─────────────────────────────────────
OPS_C="$WORKDIR1355/ops-c"
REPO_C="$WORKDIR1355/repo-c"
mkdir -p "$REPO_C"
ac_oak_pack "$OPS_C/pack.toml" ""
ac_oak_project_toml "$WORKDIR1355/project-c.toml" "tick-c" "$REPO_C" "$OPS_C"

ac_log "fixture C: a pack without [gvf.inbound] must not crash the tick"
tick_pair1355 "fixture C" "$WORKDIR1355/project-c.toml"
W_C="$OPS_C/oak/weights.json"
ac_assert_jq '.gvf.inbound.V == {}' "$(cat "$W_C")" \
  "no [gvf.inbound] → no extra GVF → inbound V stays empty"
ac_assert_jq '(.gvf.purpose.Q["0|1"]["idle"]) < 1.0' "$(cat "$W_C")" \
  "the purpose Q must still update without any extra GVF"

echo PASS
