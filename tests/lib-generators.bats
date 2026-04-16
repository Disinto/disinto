#!/usr/bin/env bats
# =============================================================================
# tests/lib-generators.bats — Regression guard for the #849 fix.
#
# Before #849, `_generate_local_model_services` emitted the forge-user env
# variable keyed by service name (`FORGE_BOT_USER_${service_name^^}`), so for
# an `[agents.llama]` block with `forge_user = "dev-qwen"` the compose file
# contained `FORGE_BOT_USER_LLAMA: "dev-qwen"`. That suffix diverges from the
# `FORGE_TOKEN_<FORGE_USER>` / `FORGE_PASS_<FORGE_USER>` convention that the
# same block uses two lines above, and it doesn't even round-trip through a
# dash-containing service name (`dev-qwen` → `DEV-QWEN`, which is not a valid
# shell identifier — see #852).
#
# The fix keys on `$user_upper` (already computed from `forge_user` via
# `tr 'a-z-' 'A-Z_'`), yielding `FORGE_BOT_USER_DEV_QWEN: "dev-qwen"`.
# =============================================================================

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export FACTORY_ROOT="${BATS_TEST_TMPDIR}/factory"
  mkdir -p "${FACTORY_ROOT}/projects"

  # Minimal compose skeleton that `_generate_local_model_services` can splice into.
  # It only needs a `volumes:` marker line and nothing below it that would be
  # re-read after the splice.
  cat > "${FACTORY_ROOT}/docker-compose.yml" <<'EOF'
services:
  agents:
    image: placeholder

volumes:
  agent-data:
EOF
}

@test "local-model agent service emits FORGE_BOT_USER keyed by forge_user (#849)" {
  cat > "${FACTORY_ROOT}/projects/test.toml" <<'EOF'
name      = "test"
repo      = "test-owner/test-repo"
forge_url = "http://localhost:3000"

[agents.llama]
base_url    = "http://10.10.10.1:8081"
model       = "qwen"
api_key     = "sk-no-key-required"
roles       = ["dev"]
forge_user  = "dev-qwen"
compact_pct = 60
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/generators.sh'
    _generate_local_model_services '${FACTORY_ROOT}/docker-compose.yml'
    cat '${FACTORY_ROOT}/docker-compose.yml'
  "

  [ "$status" -eq 0 ]
  # New, forge_user-keyed suffix is present with the right value.
  [[ "$output" == *'FORGE_BOT_USER_DEV_QWEN: "dev-qwen"'* ]]
  # Legacy service-name-keyed suffix must not be emitted.
  [[ "$output" != *'FORGE_BOT_USER_LLAMA'* ]]
}

@test "local-model agent service keys FORGE_BOT_USER to forge_user even when it differs from service name (#849)" {
  # Exercise the case the issue calls out: two agents in the same factory
  # whose service names are identical (`[agents.llama]`) but whose
  # forge_users diverge would previously both have emitted
  # `FORGE_BOT_USER_LLAMA`. With the fix each emission carries its own
  # forge_user-derived suffix.
  cat > "${FACTORY_ROOT}/projects/a.toml" <<'EOF'
name      = "a"
repo      = "a/a"
forge_url = "http://localhost:3000"

[agents.dev]
base_url   = "http://10.10.10.1:8081"
model      = "qwen"
api_key    = "sk-no-key-required"
roles      = ["dev"]
forge_user = "review-qwen"
EOF

  run bash -c "
    set -euo pipefail
    source '${ROOT}/lib/generators.sh'
    _generate_local_model_services '${FACTORY_ROOT}/docker-compose.yml'
    cat '${FACTORY_ROOT}/docker-compose.yml'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *'FORGE_BOT_USER_REVIEW_QWEN: "review-qwen"'* ]]
  [[ "$output" != *'FORGE_BOT_USER_DEV:'* ]]
}
