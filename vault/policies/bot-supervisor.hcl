# vault/policies/bot-supervisor.hcl
#
# Supervisor agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the supervisor-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/supervisor" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/supervisor" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
