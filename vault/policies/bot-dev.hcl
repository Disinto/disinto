# vault/policies/bot-dev.hcl
#
# Dev agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the dev-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/dev" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/dev" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
