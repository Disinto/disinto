# vault/policies/bot-vault.hcl
#
# Vault agent (the legacy edge dispatcher / vault-action runner): reads its
# own bot KV namespace + the shared forge URL. Attached to the vault-agent
# Nomad job via workload identity (S2.4).
#
# NOTE: distinct from the runner-* policies, which gate per-secret access
# for vault-runner ephemeral dispatches (Step 5).

path "kv/data/disinto/bots/vault/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/vault/*" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge/*" {
  capabilities = ["read"]
}
