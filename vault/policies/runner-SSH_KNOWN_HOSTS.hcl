# vault/policies/runner-SSH_KNOWN_HOSTS.hcl
#
# Per-secret runner policy: SSH known_hosts bundle paired with SSH_KEY.
# Rendered as a file next to the private key. Same least-privilege rule as
# the other runner-* policies — one KV path, no wildcards.

path "kv/data/disinto/runner/SSH_KNOWN_HOSTS" {
  capabilities = ["read"]
}
