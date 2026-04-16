# vault/policies/bot-planner.hcl
#
# Planner agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the planner-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/planner/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/planner/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge/*" {
  capabilities = ["read"]
}
