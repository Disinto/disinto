# vault/policies/service-edge-chat.hcl
#
# Chat-Claude factory control surface secrets (#650). The caddy task in
# nomad/jobs/edge.hcl renders these into file mounts consumed by the chat
# subprocess:
#
#   - FACTORY_FORGE_PAT — admin PAT used by the forge-api MCP for issue/PR
#     CRUD against https://self.disinto.ai/forge/api/v1.
#   - NOMAD_TOKEN       — scoped ACL token (namespace=default, submit/read/
#     list-job + read-logs). The Nomad policy this token is bound to is
#     installed via `nomad acl policy apply` — see
#     nomad/acl-policies/chat-ops.hcl.
#
# Separate from service-dispatcher (which covers ops-repo + runner secrets):
# the dispatcher has no business reading the operator's Forge PAT, and the
# chat control surface has no business listing runner secret paths.

path "kv/data/disinto/chat" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/chat" {
  capabilities = ["list", "read"]
}
