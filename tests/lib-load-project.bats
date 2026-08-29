#!/usr/bin/env bats
# =============================================================================
# tests/lib-load-project.bats — Regression guard for the #862 fix.
#
# TOML allows dashes in bare keys, so `[agents.dev-qwen2]` is a valid section
# header. Before #862, load-project.sh translated the section name into a
# shell variable name via Python's `.upper()` alone, which kept the dash and
# produced `AGENT_DEV-QWEN2_BASE_URL`. `export "AGENT_DEV-QWEN2_..."` is
# rejected by bash ("not a valid identifier"), and with `set -euo pipefail`
# anywhere up-stack that error aborts load-project.sh — effectively crashing
# the factory on the N+1 run after a dashed agent was hired.
#
# The fix normalizes via `.upper().replace('-', '_')`, matching the
# `tr 'a-z-' 'A-Z_'` convention already used in hire-agent.sh and
# generators.sh.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TOML="${BATS_TEST_TMPDIR}/test.toml"
}

@test "dashed [agents.*] section name parses without error" {
  cat > "$TOML" <<EOF
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[agents.dev-qwen2]
base_url    = "http://10.10.10.1:8081"
model       = "unsloth/Qwen3.5-35B-A3B"
api_key     = "sk-no-key-required"
roles       = ["dev"]
forge_user  = "dev-qwen2"
compact_pct = 60
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"BASE=\${AGENT_DEV_QWEN2_BASE_URL:-MISSING}\"
    echo \"MODEL=\${AGENT_DEV_QWEN2_MODEL:-MISSING}\"
    echo \"ROLES=\${AGENT_DEV_QWEN2_ROLES:-MISSING}\"
    echo \"FORGE_USER=\${AGENT_DEV_QWEN2_FORGE_USER:-MISSING}\"
    echo \"COMPACT=\${AGENT_DEV_QWEN2_COMPACT_PCT:-MISSING}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=http://10.10.10.1:8081"* ]]
  [[ "$output" == *"MODEL=unsloth/Qwen3.5-35B-A3B"* ]]
  [[ "$output" == *"ROLES=dev"* ]]
  [[ "$output" == *"FORGE_USER=dev-qwen2"* ]]
  [[ "$output" == *"COMPACT=60"* ]]
}

@test "dashless [agents.*] section name still works" {
  cat > "$TOML" <<EOF
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[agents.llama]
base_url    = "http://10.10.10.1:8081"
model       = "qwen"
api_key     = "sk-no-key-required"
roles       = ["dev"]
forge_user  = "dev-llama"
compact_pct = 60
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"BASE=\${AGENT_LLAMA_BASE_URL:-MISSING}\"
    echo \"MODEL=\${AGENT_LLAMA_MODEL:-MISSING}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=http://10.10.10.1:8081"* ]]
  [[ "$output" == *"MODEL=qwen"* ]]
}

@test "multiple dashes in [agents.*] name all normalized" {
  cat > "$TOML" <<EOF
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[agents.review-qwen-3b]
base_url    = "http://10.10.10.1:8082"
model       = "qwen-3b"
api_key     = "sk-no-key-required"
roles       = ["review"]
forge_user  = "review-qwen-3b"
compact_pct = 60
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"BASE=\${AGENT_REVIEW_QWEN_3B_BASE_URL:-MISSING}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE=http://10.10.10.1:8082"* ]]
}

@test "hire-agent rejects dash-starting agent name" {
  run bash -c "
    FACTORY_ROOT='${ROOT}' \
    FORGE_URL='http://127.0.0.1:1' \
    FORGE_TOKEN=x \
    bash -c '
      set -euo pipefail
      source \"\${FACTORY_ROOT}/lib/hire-agent.sh\"
      disinto_hire_an_agent -foo dev
    '
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid agent name"* ]]
}

@test "hire-agent rejects uppercase agent name" {
  run bash -c "
    FACTORY_ROOT='${ROOT}' \
    FORGE_URL='http://127.0.0.1:1' \
    FORGE_TOKEN=x \
    bash -c '
      set -euo pipefail
      source \"\${FACTORY_ROOT}/lib/hire-agent.sh\"
      disinto_hire_an_agent DevQwen dev
    '
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid agent name"* ]]
}

@test "hire-agent rejects underscore agent name" {
  run bash -c "
    FACTORY_ROOT='${ROOT}' \
    FORGE_URL='http://127.0.0.1:1' \
    FORGE_TOKEN=x \
    bash -c '
      set -euo pipefail
      source \"\${FACTORY_ROOT}/lib/hire-agent.sh\"
      disinto_hire_an_agent dev_qwen dev
    '
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid agent name"* ]]
}

@test "hire-agent rejects trailing dash agent name" {
  run bash -c "
    FACTORY_ROOT='${ROOT}' \
    FORGE_URL='http://127.0.0.1:1' \
    FORGE_TOKEN=x \
    bash -c '
      set -euo pipefail
      source \"\${FACTORY_ROOT}/lib/hire-agent.sh\"
      disinto_hire_an_agent dev- dev
    '
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid agent name"* ]]
}

@test "hire-agent rejects consecutive-dash agent name" {
  run bash -c "
    FACTORY_ROOT='${ROOT}' \
    FORGE_URL='http://127.0.0.1:1' \
    FORGE_TOKEN=x \
    bash -c '
      set -euo pipefail
      source \"\${FACTORY_ROOT}/lib/hire-agent.sh\"
      disinto_hire_an_agent dev--qwen dev
    '
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid agent name"* ]]
}

# -------------------------------------------------------------------------
# #852 defence: the export loops must warn-and-skip invalid identifiers
# rather than tank `set -euo pipefail`. Hire-agent's up-front reject
# (tests above) is the primary line of defence, but a hand-edited TOML —
# e.g. [mirrors] my-mirror = "…" or a quoted [agents."weird name"] — can
# still produce invalid shell identifiers downstream. The guard keeps
# the factory loading the rest of the file instead of crash-looping.
# -------------------------------------------------------------------------

@test "[mirrors] dashed key: warn-and-skip, does not crash under set -e" {
  cat > "$TOML" <<EOF
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[mirrors]
good = "https://example.com/good"
bad-name = "https://example.com/bad"
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/load-project.sh' '$TOML' 2>&1
    echo \"GOOD=\${MIRROR_GOOD:-MISSING}\"
  "

  # Whole load did not abort under set -e.
  [ "$status" -eq 0 ]
  # The valid mirror still loads.
  [[ "$output" == *"GOOD=https://example.com/good"* ]]
  # The invalid one triggers a warning; load continues instead of crashing.
  [[ "$output" == *"skipping invalid shell identifier"* ]]
  [[ "$output" == *"MIRROR_BAD-NAME"* ]]
}

# -------------------------------------------------------------------------
# #1085: inside the agents container the jobspec sets one FORGE_REPO for the
# whole container, but in a multi-project factory each TOML's own `repo` must
# win — otherwise every project's poll queries the jobspec's forge repo.
# The DISINTO_CONTAINER guard still skips host-perspective values
# (FORGE_URL, PROJECT_REPO_ROOT, OPS_REPO_ROOT), and an empty TOML value
# (repo-less TOML) must never clear the jobspec value.
# -------------------------------------------------------------------------

@test "container: TOML repo overrides jobspec FORGE_REPO, host-perspective values stay" {
  cat > "$TOML" <<EOF
name      = "selenocyte"
repo      = "selenocyte-org/selenocyte"
forge_url = "http://localhost:3000"
repo_root = "/home/admin/repos/selenocyte"
ops_repo  = "selenocyte-org/selenocyte-ops"
primary_branch = "trunk"

[ci]
woodpecker_repo_id = 42
EOF

  run bash -c "
    set -euo pipefail
    export DISINTO_CONTAINER=1
    export FORGE_REPO=disinto-admin/disinto
    export FORGE_URL=http://forgejo:3000
    export PROJECT_REPO_ROOT=/home/agent/repos/selenocyte
    export OPS_REPO_ROOT=/home/agent/repos/selenocyte-ops
    export PRIMARY_BRANCH=main
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"REPO=\${FORGE_REPO}\"
    echo \"API=\${FORGE_API}\"
    echo \"OPSREPO=\${FORGE_OPS_REPO}\"
    echo \"BRANCH=\${PRIMARY_BRANCH}\"
    echo \"WPID=\${WOODPECKER_REPO_ID}\"
    echo \"URL=\${FORGE_URL}\"
    echo \"ROOT=\${PROJECT_REPO_ROOT}\"
    echo \"OPSROOT=\${OPS_REPO_ROOT}\"
  "

  [ "$status" -eq 0 ]
  # Repo-identity keys take the TOML values…
  [[ "$output" == *"REPO=selenocyte-org/selenocyte"* ]]
  [[ "$output" == *"API=http://forgejo:3000/api/v1/repos/selenocyte-org/selenocyte"* ]]
  [[ "$output" == *"OPSREPO=selenocyte-org/selenocyte-ops"* ]]
  [[ "$output" == *"BRANCH=trunk"* ]]
  [[ "$output" == *"WPID=42"* ]]
  # …FORGE_API is re-derived against the container forge URL, not localhost.
  # Host-perspective values are skipped…
  [[ "$output" == *"URL=http://forgejo:3000"* ]]
  [[ "$output" == *"ROOT=/home/agent/repos/selenocyte"* ]]
  [[ "$output" == *"OPSROOT=/home/agent/repos/selenocyte-ops"* ]]
}

@test "container: TOML without repo keeps the jobspec FORGE_REPO" {
  cat > "$TOML" <<EOF
name      = "solo"
forge_url = "http://localhost:3000"
EOF

  run bash -c "
    set -euo pipefail
    export DISINTO_CONTAINER=1
    export FORGE_REPO=disinto-admin/disinto
    export FORGE_URL=http://forgejo:3000
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"REPO=\${FORGE_REPO}\"
    echo \"API=\${FORGE_API}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO=disinto-admin/disinto"* ]]
  [[ "$output" == *"API=http://forgejo:3000/api/v1/repos/disinto-admin/disinto"* ]]
}

@test "container: identity vars not set by the jobspec still load from TOML" {
  # WOODPECKER_REPO_ID / FORGE_OPS_REPO are absent from the jobspec, so the
  # skip-if-set guard never fires — plain export path, container or not.
  cat > "$TOML" <<EOF
name      = "solo"
repo      = "solo-org/solo"
ops_repo  = "solo-org/solo-ops"

[ci]
woodpecker_repo_id = 7
EOF

  run bash -c "
    set -euo pipefail
    export DISINTO_CONTAINER=1
    export FORGE_REPO=solo-org/solo
    export FORGE_URL=http://forgejo:3000
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"OPSREPO=\${FORGE_OPS_REPO:-MISSING}\"
    echo \"WPID=\${WOODPECKER_REPO_ID:-MISSING}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"OPSREPO=solo-org/solo-ops"* ]]
  [[ "$output" == *"WPID=7"* ]]
}

@test "host: DISINTO_CONTAINER unset still applies TOML values normally" {
  cat > "$TOML" <<EOF
name      = "hostproj"
repo      = "host-owner/host-proj"
forge_url = "http://localhost:3000"
EOF

  # Unset the container-injected vars explicitly: CI/agent containers export
  # DISINTO_CONTAINER=1 and forge env, which would take the container path.
  run bash -c "
    set -euo pipefail
    unset DISINTO_CONTAINER FORGE_REPO FORGE_URL FORGE_API FORGE_API_BASE FORGE_WEB FORGE_OPS_REPO FORGE_REPO_OWNER WOODPECKER_REPO_ID
    source '${ROOT}/lib/load-project.sh' '$TOML'
    echo \"REPO=\${FORGE_REPO}\"
    echo \"API=\${FORGE_API}\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO=host-owner/host-proj"* ]]
  [[ "$output" == *"API=http://localhost:3000/api/v1/repos/host-owner/host-proj"* ]]
}

@test "[agents.*] quoted section with space: warn-and-skip, does not crash" {
  # TOML permits quoted keys with arbitrary characters. A hand-edited
  # `[agents."weird name"]` would survive the Python .replace('-', '_')
  # (because it has no dash) but still contains a space, which would
  # yield AGENT_WEIRD NAME_BASE_URL — not a valid identifier.
  cat > "$TOML" <<'EOF'
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[agents.llama]
base_url = "http://10.10.10.1:8081"
model    = "qwen"

[agents."weird name"]
base_url = "http://10.10.10.1:8082"
model    = "qwen-bad"
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/load-project.sh' '$TOML' 2>&1
    echo \"LLAMA=\${AGENT_LLAMA_BASE_URL:-MISSING}\"
  "

  # The sane sibling must still be loaded despite the malformed neighbour.
  [ "$status" -eq 0 ]
  [[ "$output" == *"LLAMA=http://10.10.10.1:8081"* ]]
  # The invalid agent's identifier triggers a warning and is skipped.
  [[ "$output" == *"skipping invalid shell identifier"* ]]
}
