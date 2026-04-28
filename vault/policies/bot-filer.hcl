# vault/policies/bot-filer.hcl
#
# Filer agent: reads its own bot KV namespace + the shared forge URL.
# The filer-bot identity is used by the gardener `file-subissues` task
# (#902) to fan out APPROVED architect pitch sub-issues — POSTing project
# repo issues and PATCHing the ops repo PR body with the `## Filed:` marker.
# Token is exposed to the gardener task as $FORGE_FILER_TOKEN via the
# service-agents composite policy (vault/policies/service-agents.hcl).

path "kv/data/disinto/bots/filer" {
  capabilities = ["read"]
}

path "kv/metadata/disinto/bots/filer" {
  capabilities = ["list", "read"]
}

path "kv/data/disinto/shared/forge" {
  capabilities = ["read"]
}
