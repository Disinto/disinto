# vault/policies/service-woodpecker.hcl
#
# Read-only access to shared Woodpecker secrets (agent secret, forge OAuth
# client). Attached to the Woodpecker Nomad job via workload identity (S2.4).
#
# Scope: kv/disinto/shared/woodpecker/* — entries owned by the operator
# and consumed by woodpecker-server + woodpecker-agent.

path "kv/data/disinto/shared/woodpecker" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/shared/woodpecker" {
  capabilities = ["list", "read"]
}
