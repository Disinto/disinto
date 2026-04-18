# vault/policies/service-chat.hcl
#
# Read-only access to shared Chat secrets (OAuth client config, forward auth
# secret). Attached to the Chat Nomad job via workload identity (S5.2).
#
# Scope: kv/disinto/shared/chat — entries owned by the operator and
# shared between the chat service and edge proxy.

path "kv/data/disinto/shared/chat" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/shared/chat" {
  capabilities = ["list", "read"]
}
