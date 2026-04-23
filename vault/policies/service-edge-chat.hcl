# vault/policies/service-edge-chat.hcl
#
# Edge-container secrets covering both subprocesses that live in the caddy
# task of nomad/jobs/edge.hcl:
#
#   Chat-Claude control surface (#650) — kv/disinto/chat:
#   - FACTORY_FORGE_PAT — admin PAT used by the forge-api MCP for issue/PR
#     CRUD against https://self.disinto.ai/forge/api/v1.
#   - NOMAD_TOKEN       — scoped ACL token (namespace=default, submit/read/
#     list-job + read-logs). The Nomad policy this token is bound to is
#     installed via `nomad acl policy apply` — see
#     nomad/acl-policies/chat-ops.hcl.
#
#   Voice bridge (#651 / #664) — kv/disinto/voice:
#   - gemini_api_key    — Google Gemini Live API key. Rendered to a FILE
#     (/secrets/gemini-api-key) rather than an env var so it is NOT
#     inherited by the chat subprocess — only the voice bridge launcher
#     reads the file and sets GEMINI_API_KEY for its own child (#662).
#
# A Nomad task can bind only one vault role, so the two subprocesses share
# this single policy. Per-subprocess isolation is enforced at launch time
# (template-to-file + scoped exec env), not at the Vault layer.
#
# Separate from service-dispatcher (which covers ops-repo + runner secrets):
# the dispatcher has no business reading the operator's Forge PAT, the
# Gemini key, or the Nomad ACL token.

path "kv/data/disinto/chat" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/chat" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/voice" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/voice" {
  capabilities = ["list", "read"]
}
