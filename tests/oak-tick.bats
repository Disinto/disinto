#!/usr/bin/env bats
# =============================================================================
# tests/oak-tick.bats — oak/tick.sh extra GVF updates from pack [gvf.*] (#1355)
#
# After sense, every pack [gvf.<name>] other than purpose contributes a
# cumulant to UPDATE.json "extra": c="r" is the purpose Q update (skipped),
# c="feature:<f>" reads x2[<f>] (a number, else 0). td.sh then steps
# gvf.<name>.V for each entry — so a dry-run tick with inbound_present=0
# still writes gvf.inbound.V[x_key]: the key EXISTS (value 0), it is not
# dropped. The purpose Q keeps updating either way, and a pack without
# [gvf.inbound] must not crash the tick.
#
# All ticks run OAK_DRY_RUN=1 against a private fixture ops dir: no organ is
# ever started, no live state is touched.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TICK1355="$ROOT/oak/tick.sh"
  PROJ1355="$BATS_TEST_TMPDIR/project.toml"
  OPS1355="$BATS_TEST_TMPDIR/ops"
  REPO1355="$BATS_TEST_TMPDIR/repo"
  cd "$BATS_TEST_TMPDIR"
  export USER="${USER:-agent}"
  export HOME="${HOME:-/tmp}"
  unset OPS_REPO_ROOT FORGE_API FORGE_TOKEN AGENT_ROLES DISINTO_CONTAINER
  mkdir -p "$OPS1355" "$REPO1355"
  touch "$OPS1355/here"
  # Fixture pack: idle-only shape (epsilon=0 → every pick is idle, no organ
  # starts) plus the extra GVF [gvf.inbound] on feature inbound_present.
  cat >"$OPS1355/pack.toml" <<'EOF'
[learn]
alpha = 0.1
gamma = 0.99
epsilon = 0
q0 = 1.0

[critic]
builtin = "present"
feature = "done"

[gvf.purpose]
c = "r"

[gvf.inbound]
c = "feature:inbound_present"

[features.here]
rule = "present"
path = "here"

[features.done]
rule = "present"
path = "done"

[features.inbound_present]
rule = "present"
path = "inbound/child_registered"

[actions.idle]
script = ""

[actions.fixture-organ]
script = "oak/fixture-organ-1355.sh"
EOF
  cat >"$PROJ1355" <<EOF
name = "tick-extra"
repo_root = "$REPO1355"
ops_repo_root = "$OPS1355"
primary_branch = "main"
EOF
}

# run_tick1355 — one OAK_DRY_RUN tick; stdout = chosen action (one line).
run_tick1355() {
  env -u AGENT_ROLES -u DISINTO_CONTAINER \
    OAK_DRY_RUN=1 bash "$TICK1355" "$PROJ1355" 2>/dev/null
}

# tick_pair1355 — a boot tick (writes last.json only) + one learning tick
# (carries the SARSA step); both must exit 0.
tick_pair1355() {
  run run_tick1355
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "idle" ] || return 1
  run run_tick1355
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
}

# --- the extra GVF path -------------------------------------------------------

@test "inbound_present=0: gvf.inbound.V has the state key with value 0" {
  run tick_pair1355
  [ "$status" -eq 0 ]
  # features: done=0, here=1, inbound_present=0 → state key "0|1|0"
  run jq -e '.gvf.inbound.V | has("0|1|0")' "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
  # cumulant 0, v = v2 = 0 → V stays 0 — but the key EXISTS
  run jq -e '.gvf.inbound.V["0|1|0"] | type == "number" and . == 0' \
    "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}

@test "inbound_present=0: the purpose Q still updates" {
  run tick_pair1355
  [ "$status" -eq 0 ]
  run jq -e '(.gvf.purpose.Q["0|1|0"]["idle"]) < 1.0' \
    "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}

@test "inbound_present=1: the cumulant moves gvf.inbound.V up" {
  mkdir -p "$OPS1355/inbound"
  touch "$OPS1355/inbound/child_registered"
  run tick_pair1355
  [ "$status" -eq 0 ]
  # key "0|1|1"; cumulant 1, v = v2 = 0 → 0 + 0.1 * (1 + 0.99 * 0 - 0) = 0.1
  run jq -e '.gvf.inbound.V["0|1|1"] | (. > 0.099 and . < 0.101)' \
    "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}

@test "pack without [gvf.inbound]: the tick does not crash" {
  cat >"$OPS1355/pack.toml" <<'EOF'
[learn]
alpha = 0.1
gamma = 0.99
epsilon = 0
q0 = 1.0

[critic]
builtin = "present"
feature = "done"

[features.here]
rule = "present"
path = "here"

[features.done]
rule = "present"
path = "done"

[actions.idle]
script = ""
EOF
  run tick_pair1355
  [ "$status" -eq 0 ]
  # no extra GVF → inbound V stays empty; the purpose Q learns
  run jq -e '.gvf.inbound.V == {}' "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
  run jq -e '(.gvf.purpose.Q["0|1"]["idle"]) < 1.0' "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}

@test "a non-inbound [gvf.<name>] is stepped into gvf.<name>.V" {
  cat >>"$OPS1355/pack.toml" <<'EOF'

[gvf.backlog]
c = "feature:here"
EOF
  run tick_pair1355
  [ "$status" -eq 0 ]
  # cumulant x[here] = 1 → 0 + 0.1 * (1 + 0.99 * 0 - 0) = 0.1
  run jq -e '.gvf.backlog.V["0|1|0"] | (. > 0.099 and . < 0.101)' \
    "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}

@test "a non-purpose [gvf.<name>] with c=r is skipped" {
  sed -i 's/^c = "feature:inbound_present"$/c = "r"/' "$OPS1355/pack.toml"
  run tick_pair1355
  [ "$status" -eq 0 ]
  run jq -e '.gvf.inbound.V == {}' "$OPS1355/oak/weights.json"
  [ "$status" -eq 0 ]
}
