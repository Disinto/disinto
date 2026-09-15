#!/usr/bin/env bash
# =============================================================================
# tests/lib/oak-fixture.sh — shared oak/tick.sh fixture for acceptance tests
#
# Sourced by the oak acceptance tests (issue-1332.sh, issue-1354.sh, ...).
# The standard idle-only fixture (pack + "here" state file + project toml)
# and the tick failure reporter live here once instead of being
# copy-pasted into every test: duplicate-detection fails a PR that repeats
# 5+ lines across shell files, and a shared fixture is the same logic by
# design (see AGENTS.md: shared helpers go in lib/).
#
# The fixtures these helpers build are deterministic: present features
# here/done (key "0|1"), critic on "done" (absent → r=0), epsilon 0,
# empty weights → every pick is idle until the SARSA table moves.
# =============================================================================

# ac_oak_pack <pack-path> <extra-actions-toml> [vault-toml]
# Write the standard idle-only oak pack to <pack-path> and create the
# fixture's $OPS/here state file (the pack's [features.here] sensor):
#   [learn] alpha=0.1 gamma=0.99 epsilon=0 q0=1.0
#   [vault]  only when <vault-toml> is non-empty
#   [critic] builtin="present" feature="done"
#   [features.here] / [features.done]  rule="present"
#   [actions.idle] script="" plus the caller's extra [actions.*] tables
ac_oak_pack() {
  local pack="$1" actions="$2" vault="${3:-}"
  local ops
  ops="$(dirname "$pack")"
  mkdir -p "$ops"
  touch "$ops/here"
  {
    cat <<'EOF'
[learn]
alpha = 0.1
gamma = 0.99
epsilon = 0
q0 = 1.0

EOF
    if [ -n "$vault" ]; then
      printf '%s\n\n' "$vault"
    fi
    cat <<'EOF'
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
    printf '%s\n' "$actions"
  } >"$pack"
}

# ac_oak_project_toml <path> <name> <repo-dir> <ops-dir>
# Write the standard 4-field fixture project toml for an ops dir.
ac_oak_project_toml() {
  local path="$1" name="$2" repo="$3" ops="$4"
  cat >"$path" <<EOF
name = "$name"
repo_root = "$repo"
ops_repo_root = "$ops"
primary_branch = "main"
EOF
}

# ac_oak_tick_fail <what> <err-file>
# ac_fail with the last line of the tick's stderr (<err-file>) appended.
ac_oak_tick_fail() {
  local what="$1" err="$2"
  local last=""
  [ -s "$err" ] && last=" — last stderr: $(tail -n1 "$err")"
  ac_fail "$what$last"
}
