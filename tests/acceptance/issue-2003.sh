#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2003.sh
#
# Issue #2003: the agents image bakes a dsh settings template for the xAI
# (Grok) provider, /opt/dsh/settings-xai.yaml, alongside the llama.cpp one.
# Nothing seeds it yet (#2004 wires the entrypoint); the image just carries it.
#
# Acceptance (hermetic: no forge, no nomad, no daemon, no docker daemon):
#   1. docker/agents/dsh-settings-xai.yaml parses and exposes
#      llm-pi-ai.providers.xai with api openai-responses, baseURL
#      https://api.x.ai/v1, no apiKeyEnv, exactly one model whose id is
#      grok-4.7, and agent-default-model provider xai / model grok-4.7.
#   2. docker/agents/Dockerfile COPYs that file to /opt/dsh/settings-xai.yaml
#      on the line immediately after the llamacpp COPY, and the llamacpp COPY
#      line itself is untouched (issue-1840.sh greps it).
#
# CI runs acceptance tests in disinto/agents:local, which has python3 but no
# PyYAML (see issue-1500.sh). So the grep assertions below always run and the
# PyYAML parse is an extra structural check when the module is importable:
# the test never fails merely because PyYAML is absent.
#
# Run via: tools/run-acceptance.sh 2003
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd grep awk cut

TEMPLATE="$REPO_ROOT/docker/agents/dsh-settings-xai.yaml"
DOCKERFILE="$REPO_ROOT/docker/agents/Dockerfile"
ac_assert_file "$TEMPLATE" "docker/agents/dsh-settings-xai.yaml must exist"
ac_assert_file "$DOCKERFILE" "docker/agents/Dockerfile must exist"

# ── AC 1a: the template names the provider, its api, baseURL and model ───────
ac_log "AC 1: dsh-settings-xai.yaml names the xai provider, api, baseURL and model"
grep -qF 'llm-pi-ai:' "$TEMPLATE" \
  || ac_fail "dsh-settings-xai.yaml must open with the llm-pi-ai: block"
grep -qE '^    xai:[[:space:]]*$' "$TEMPLATE" \
  || ac_fail "dsh-settings-xai.yaml must define providers.xai"
grep -qF 'api: openai-responses' "$TEMPLATE" \
  || ac_fail "the xai provider must use api: openai-responses"
grep -qF 'baseURL: https://api.x.ai/v1' "$TEMPLATE" \
  || ac_fail "the xai provider must set baseURL: https://api.x.ai/v1"
grep -qF 'id: grok-4.7' "$TEMPLATE" \
  || ac_fail "the xai provider must declare model id grok-4.7"
grep -qF 'agent-default-model:' "$TEMPLATE" \
  || ac_fail "the template must set agent-default-model"
grep -qF 'provider: xai' "$TEMPLATE" \
  || ac_fail "agent-default-model must name provider xai"
grep -qF 'model: grok-4.7' "$TEMPLATE" \
  || ac_fail "agent-default-model must name model grok-4.7"

ac_log "AC 1: the xai provider block carries no apiKeyEnv (it uses the stored OAuth grant)"
# The provider body only — the header comment may name apiKeyEnv in prose.
XAI_BLOCK="$(awk '
  /^    xai:/ { in_block = 1; next }
  in_block && /^[^[:space:]]/ { exit }
  in_block { print }
' "$TEMPLATE")"
[ -n "$XAI_BLOCK" ] || ac_fail "could not extract the providers.xai block from dsh-settings-xai.yaml"
apiKeyEnv_hits="$(printf '%s\n' "$XAI_BLOCK" | grep -n 'apiKeyEnv' || true)"
if [ -n "$apiKeyEnv_hits" ]; then
  ac_fail "the xai provider must not name apiKeyEnv (found: ${apiKeyEnv_hits})"
fi
ac_log "AC 1 OK"

# ── AC 1b: PyYAML structural parse (skipped when the module is unavailable) ──
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  ac_log "AC 1: parsing the template with PyYAML"
  python3 - "$TEMPLATE" <<'PY' || ac_fail "PyYAML structural check of dsh-settings-xai.yaml failed"
import sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
assert isinstance(doc, dict), "top level must be a mapping"
prov = doc["llm-pi-ai"]["providers"]["xai"]
assert prov["api"] == "openai-responses", "api must be openai-responses"
assert prov["baseURL"] == "https://api.x.ai/v1", "baseURL must be https://api.x.ai/v1"
assert "apiKeyEnv" not in prov, "the xai provider must not name apiKeyEnv"
models = prov["models"]
assert len(models) == 1, "exactly one model must be declared"
assert models[0]["id"] == "grok-4.7", "the model id must be grok-4.7"
default = doc["agent-default-model"]
assert default["provider"] == "xai", "agent-default-model provider must be xai"
assert default["model"] == "grok-4.7", "agent-default-model model must be grok-4.7"
PY
  ac_log "AC 1: PyYAML parse OK"
else
  ac_log "PyYAML unavailable in this container — grep assertions above cover the same invariants"
fi

# ── AC 2: the Dockerfile COPYs it right after the llamacpp COPY ───────────────
ac_log "AC 2: Dockerfile COPYs the xai template to /opt/dsh/settings-xai.yaml"
llamacpp_copy='COPY docker/agents/dsh-settings-llamacpp.yaml /opt/dsh/settings-llamacpp.yaml'
xai_copy='COPY docker/agents/dsh-settings-xai.yaml /opt/dsh/settings-xai.yaml'

llamacpp_count="$(grep -cF -- "$llamacpp_copy" "$DOCKERFILE" || true)"
ac_assert_eq "$llamacpp_count" "1" \
  "the llamacpp COPY line must appear exactly once in docker/agents/Dockerfile (got ${llamacpp_count}) — issue-1840.sh greps it"
# issue-1840.sh asserts '/opt/dsh/settings-llamacpp.yaml' appears once; keep that true.
seed_count="$(grep -cF '/opt/dsh/settings-llamacpp.yaml' "$DOCKERFILE" || true)"
ac_assert_eq "$seed_count" "1" \
  "issue-1840.sh expects '/opt/dsh/settings-llamacpp.yaml' once in docker/agents/Dockerfile (got ${seed_count})"

xai_count="$(grep -cF -- "$xai_copy" "$DOCKERFILE" || true)"
ac_assert_eq "$xai_count" "1" \
  "the xai COPY line must appear exactly once in docker/agents/Dockerfile (got ${xai_count})"

ll_line="$(grep -nF -- "$llamacpp_copy" "$DOCKERFILE" | head -n1 | cut -d: -f1)"
xa_line="$(grep -nF -- "$xai_copy" "$DOCKERFILE" | head -n1 | cut -d: -f1)"
if [ -z "$ll_line" ] || [ -z "$xa_line" ]; then
  ac_fail "could not locate the llamacpp or xai COPY line in docker/agents/Dockerfile"
fi
ac_assert_eq "$xa_line" "$((ll_line + 1))" \
  "the xai COPY must sit on the line right after the llamacpp COPY (llamacpp at ${ll_line}, xai at ${xa_line})"

ac_log "AC 2 OK"

ac_pass
