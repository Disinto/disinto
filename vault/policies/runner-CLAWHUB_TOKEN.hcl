# vault/policies/runner-CLAWHUB_TOKEN.hcl
#
# Per-secret runner policy: ClawHub token for skill-registry publish.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/CLAWHUB_TOKEN" {
  capabilities = ["read"]
}
