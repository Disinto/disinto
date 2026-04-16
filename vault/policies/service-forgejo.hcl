# vault/policies/service-forgejo.hcl
#
# Read-only access to shared Forgejo secrets (admin password, OAuth client
# config). Attached to the Forgejo Nomad job via workload identity (S2.4).
#
# Scope: kv/disinto/shared/forgejo/* — entries owned by the operator and
# shared between forgejo + the chat OAuth client (issue #855 lineage).

path "kv/data/disinto/shared/forgejo/*" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/shared/forgejo/*" {
  capabilities = ["list", "read"]
}
