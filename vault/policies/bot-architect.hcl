# vault/policies/bot-architect.hcl
#
# Architect agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the architect-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/architect/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/architect/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge/*" {
  capabilities = ["read"]
}
