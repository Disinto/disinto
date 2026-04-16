# vault/policies/runner-NPM_TOKEN.hcl
#
# Per-secret runner policy: npm registry auth token for package publish.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/NPM_TOKEN" {
  capabilities = ["read"]
}
