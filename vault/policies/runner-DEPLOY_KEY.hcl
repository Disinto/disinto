# vault/policies/runner-DEPLOY_KEY.hcl
#
# Per-secret runner policy: SSH deploy key for git push to a release target.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/DEPLOY_KEY" {
  capabilities = ["read"]
}
