# vault/policies/runner-DOCKER_HUB_TOKEN.hcl
#
# Per-secret runner policy: Docker Hub access token for image push.
# vault-runner (Step 5) composes only the runner-* policies named by the
# dispatching action's `secrets = [...]` list, so this policy intentionally
# scopes a single KV path — no wildcards, no list capability.

path "kv/data/disinto/runner/DOCKER_HUB_TOKEN" {
  capabilities = ["read"]
}
