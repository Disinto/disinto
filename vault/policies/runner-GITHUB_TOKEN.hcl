# vault/policies/runner-GITHUB_TOKEN.hcl
#
# Per-secret runner policy: GitHub PAT for cross-mirror push / API calls.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/GITHUB_TOKEN" {
  capabilities = ["read"]
}
