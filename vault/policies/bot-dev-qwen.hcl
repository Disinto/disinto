# vault/policies/bot-dev-qwen.hcl
#
# Local-Qwen dev agent (agents-llama profile): reads its own bot KV
# namespace + the shared forge URL. Attached to the dev-qwen Nomad job
# via workload identity (S2.4). KV path mirrors the bot basename:
# kv/disinto/bots/dev-qwen/*.

path "kv/data/disinto/bots/dev-qwen" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/dev-qwen" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
