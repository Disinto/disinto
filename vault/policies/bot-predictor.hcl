# vault/policies/bot-predictor.hcl
#
# Predictor agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the predictor-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/predictor/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/predictor/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge/*" {
  capabilities = ["read"]
}
