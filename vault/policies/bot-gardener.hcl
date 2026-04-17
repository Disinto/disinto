# vault/policies/bot-gardener.hcl
#
# Gardener agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the gardener-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/gardener" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/gardener" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
