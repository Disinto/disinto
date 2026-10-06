# vault/policies/service-edge-chat.hcl
#
# Read access to kv/disinto/chat for both tasks of nomad/jobs/edge.hcl.
# The path and policy names are historical (#650); the path is not chat-only:
#   - forge_pat   — the caddy task renders /secrets/forge-pat
#     (FACTORY_FORGE_PAT_FILE), which the dispatcher pushes vault results
#     with; the snapshot task renders it as FACTORY_FORGE_PAT.
#   - sidecar_forge_token — the caddy task renders /secrets/sidecar-forge-token,
#     the forge token the dispatcher gives the reproduce/triage/verify sidecars.
#   - nomad_token — the snapshot task renders it as NOMAD_TOKEN.
#
# Separate from service-dispatcher (ops-repo + runner secrets).

path "kv/data/disinto/chat" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/chat" {
  capabilities = ["list", "read"]
}
