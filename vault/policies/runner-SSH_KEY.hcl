# vault/policies/runner-SSH_KEY.hcl
#
# Per-secret runner policy: SSH private key for action-container access to
# remote compute (sim hosts, builders). Rendered as a 0400 file, never an
# env var. vault-runner composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/SSH_KEY" {
  capabilities = ["read"]
}
