# nomad/acl-policies/chat-ops.hcl
#
# Nomad ACL policy for the chat-Claude factory control surface (#650). The
# token bound to this policy is stored in Vault at kv/disinto/chat under
# key `nomad_token` and rendered into the caddy task at /secrets/nomad-token
# by nomad/jobs/edge.hcl. The chat subprocess reads it as NOMAD_TOKEN via
# entrypoint-edge.sh.
#
# Scope (from #650):
#   - namespace "default": submit-job, read-job, list-jobs, read-logs
#   - global agent: read (status checks)
#
# Explicitly NOT granted:
#   - write-job across other namespaces, node-write, acl-any. Sandboxed
#     operator ≠ cluster admin. Deny-list in chat-settings.json also blocks
#     `nomad system gc` and `nomad acl *` at the shell layer.
#
# Install (one-shot, after cluster-up):
#   nomad acl policy apply -description "chat-Claude operator scope" \
#     chat-ops nomad/acl-policies/chat-ops.hcl
#   nomad acl token create -name=chat-ops -policy=chat-ops -type=client
#
# Store the resulting token's Secret ID in Vault:
#   vault kv patch kv/disinto/chat nomad_token=<secret>

namespace "default" {
  policy       = "read"
  capabilities = [
    "submit-job",
    "read-job",
    "list-jobs",
    "read-logs",
    "alloc-lifecycle",
    "read-job-scaling",
  ]
}

agent {
  policy = "read"
}

node {
  policy = "read"
}
