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
