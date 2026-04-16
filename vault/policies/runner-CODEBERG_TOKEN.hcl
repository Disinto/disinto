# vault/policies/runner-CODEBERG_TOKEN.hcl
#
# Per-secret runner policy: Codeberg PAT for upstream-repo mirror push.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/CODEBERG_TOKEN" {
  capabilities = ["read"]
}
