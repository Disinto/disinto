# vault/policies/service-agents-grok.hcl
#
# Policy for the Grok agent jobs (agents-dev-grok, agents-review-grok;
# 2026-10-03). service-agents.hcl unchanged, plus the two forge identities
# only these jobs hold: kv/disinto/bots/dev-grok (dev-grok-bot) and
# kv/disinto/bots/review-grok (review-grok-bot). Keep the copied part in
# step with service-agents.hcl.

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

# ── Shared CI config (Woodpecker token — #1114) ──────────────────────────────
path "kv/data/disinto/shared/ci" {
  capabilities = ["read"]
}

# ── Grok agents' own identities ──────────────────────────────────────────────
path "kv/data/disinto/bots/dev-grok" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/dev-grok" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/bots/review-grok" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/review-grok" {
  capabilities = ["list", "read"]
}
