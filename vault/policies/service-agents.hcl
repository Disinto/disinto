# vault/policies/service-agents.hcl
#
# Composite policy for the `agents` Nomad job (S4.1, issue #955).
# Grants read access to all 7 bot KV namespaces + shared forge config,
# so a single job running all agent roles can pull per-bot tokens from
# Vault via workload identity.

# ── Per-bot KV paths (token + pass per role) ─────────────────────────────────
path "kv/data/disinto/bots/dev" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/dev" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/review" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/review" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/gardener" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/gardener" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/architect" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/architect" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/planner" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/planner" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/predictor" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/predictor" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/supervisor" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/supervisor" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/vault" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/vault" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/filer" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/filer" {
  capabilities = ["list", "read"]
}

# ── Shared forge config (URL, bot usernames) ─────────────────────────────────
path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
