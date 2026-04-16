# vault/policies/dispatcher.hcl
#
# Edge dispatcher policy: needs to enumerate the runner secret namespace
# (to check secret presence before dispatching) and read the shared
# ops-repo credentials (token + clone URL) it uses to fetch action TOMLs.
#
# Scope:
#   - kv/disinto/runner/*       — read all per-secret values + list keys
#   - kv/disinto/shared/ops-repo/* — read the ops-repo creds bundle
#
# The actual ephemeral runner container created per dispatch gets the
# narrow runner-<NAME> policies, NOT this one. This policy stays bound
# to the long-running dispatcher only.

path "kv/data/disinto/runner/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/runner/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/ops-repo/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/shared/ops-repo/*" {
  capabilities = ["list", "read"]
}
