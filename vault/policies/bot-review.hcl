# vault/policies/bot-review.hcl
#
# Review agent: reads its own bot KV namespace + the shared forge URL.
# Attached to the review-agent Nomad job via workload identity (S2.4).

path "kv/data/disinto/bots/review/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/review/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge/*" {
  capabilities = ["read"]
}
