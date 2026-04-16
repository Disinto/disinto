<!-- last-reviewed: 6bdbeb5bd2a200ff1b23724564da9383193f3e30 -->
# vault/policies/ — Agent Instructions

HashiCorp Vault ACL policies for the disinto factory. One `.hcl` file per
policy; the basename (minus `.hcl`) is the Vault policy name applied to it.
Synced into Vault by `tools/vault-apply-policies.sh` (idempotent — see the
script header for the contract).

This directory is part of the **Nomad+Vault migration (Step 2)** — see
issues #879–#884. Policies attach to Nomad jobs via workload identity in
S2.4; this PR only lands the files + apply script.

## Naming convention

| Prefix | Audience | KV scope |
|---|---|---|
| `service-<name>.hcl`  | Long-running platform services (forgejo, woodpecker) | `kv/data/disinto/shared/<name>/*` |
| `bot-<name>.hcl`      | Per-agent jobs (dev, review, gardener, …)            | `kv/data/disinto/bots/<name>/*` + shared forge URL |
| `runner-<TOKEN>.hcl`  | Per-secret policy for vault-runner ephemeral dispatch | exactly one `kv/data/disinto/runner/<TOKEN>` path |
| `dispatcher.hcl`      | Long-running edge dispatcher                         | `kv/data/disinto/runner/*` + `kv/data/disinto/shared/ops-repo/*` |

The KV mount name `kv/` is the convention this migration uses (mounted as
KV v2). Vault addresses KV v2 data at `kv/data/<path>` and metadata at
`kv/metadata/<path>` — policies that need `list` always target the
`metadata` path; reads target `data`.

## Policy → KV path summary

| Policy | Reads |
|---|---|
| `service-forgejo` | `kv/data/disinto/shared/forgejo/*` |
| `service-woodpecker` | `kv/data/disinto/shared/woodpecker/*` |
| `bot-<role>` (dev, review, gardener, architect, planner, predictor, supervisor, vault, dev-qwen) | `kv/data/disinto/bots/<role>/*` + `kv/data/disinto/shared/forge/*` |
| `runner-<TOKEN>` (GITHUB\_TOKEN, CODEBERG\_TOKEN, CLAWHUB\_TOKEN, DEPLOY\_KEY, NPM\_TOKEN, DOCKER\_HUB\_TOKEN) | `kv/data/disinto/runner/<TOKEN>` (exactly one) |
| `dispatcher` | `kv/data/disinto/runner/*` + `kv/data/disinto/shared/ops-repo/*` |

## Why one policy per runner secret

`vault-runner` (Step 5) reads each action TOML's `secrets = [...]` list
and composes only those `runner-<NAME>` policies onto the per-dispatch
ephemeral token. Wildcards or batched policies would hand the runner more
secrets than the action declared — defeats AD-006 (least-privilege per
external action). Adding a new declarable secret = adding one new
`runner-<NAME>.hcl` here + extending the SECRETS allow-list in vault-action
validation.

## Adding a new policy

1. Drop a file matching one of the four naming patterns above. Use an
   existing file in the same family as the template — comment header,
   capability list, and KV path layout should match the family.
2. Run `tools/vault-apply-policies.sh --dry-run` to confirm the new
   basename appears in the planned-work list with the expected SHA.
3. Run `tools/vault-apply-policies.sh` against a Vault instance to
   create it; re-run to confirm it reports `unchanged`.
4. The CI fmt + validate step lands in S2.6 (#884). Until then
   `vault policy fmt <file>` locally is the fastest sanity check.

## JWT-auth roles (S2.3)

Policies are inert until a Vault token carrying them is minted. In this
migration that mint path is JWT auth — Nomad jobs exchange their
workload-identity JWT for a Vault token via
`auth/jwt-nomad/role/<name>` → `token_policies = ["<policy>"]`. The
role bindings live in [`../roles.yaml`](../roles.yaml); the script that
enables the auth method + writes the config + applies roles is
[`lib/init/nomad/vault-nomad-auth.sh`](../../lib/init/nomad/vault-nomad-auth.sh).
The applier is [`tools/vault-apply-roles.sh`](../../tools/vault-apply-roles.sh).

### Role → policy naming convention

Role name == policy name, 1:1. `vault/roles.yaml` carries one entry per
`vault/policies/*.hcl` file:

```yaml
roles:
  - name:      service-forgejo      # Vault role
    policy:    service-forgejo      # ACL policy attached to minted tokens
    namespace: default              # bound_claims.nomad_namespace
    job_id:    forgejo              # bound_claims.nomad_job_id
```

The role name is what jobspecs reference via `vault { role = "..." }` —
keep it identical to the policy basename so an S2.1↔S2.3 drift (new
policy without a role, or vice versa) shows up in one directory review,
not as a runtime "permission denied" at job placement.

`bound_claims.nomad_job_id` is the actual `job "..."` name in the
jobspec, which may differ from the policy name (e.g. policy
`service-forgejo` binds to job `forgejo`). Update it when each bot's or
runner's jobspec lands.

### Adding a new service

1. Write `vault/policies/<name>.hcl` using the naming-table family that
   fits (`service-`, `bot-`, `runner-`, or standalone).
2. Add a matching entry to `vault/roles.yaml` with all four fields
   (`name`, `policy`, `namespace`, `job_id`).
3. Apply both — either in one shot via `lib/init/nomad/vault-nomad-auth.sh`
   (policies → roles → nomad SIGHUP), or granularly via
   `tools/vault-apply-policies.sh` + `tools/vault-apply-roles.sh`.
4. Reference the role in the consuming jobspec's `vault { role = "<name>" }`.

### Token shape

All roles share the same token shape, hardcoded in
`tools/vault-apply-roles.sh`:

| Field | Value |
|---|---|
| `bound_audiences` | `["vault.io"]` — matches `default_identity.aud` in `nomad/server.hcl` |
| `token_type` | `service` — auto-revoked when the task exits |
| `token_ttl` | `1h` |
| `token_max_ttl` | `24h` |

Bumping any of these is a knowing, repo-wide change. Per-role overrides
would let one service's tokens outlive the others — add a field to
`vault/roles.yaml` and the applier at the same time if that ever
becomes necessary.

## What this directory does NOT own

- **Attaching policies to Nomad jobs.** That's S2.4 (#882) via the
  jobspec `template { vault { policies = […] } }` stanza — the role
  name in `vault { role = "..." }` is what binds the policy.
- **Writing the secret values themselves.** That's S2.2 (#880) via
  `tools/vault-import.sh`.
- **CI policy fmt + validate + roles.yaml check.** That's S2.6 (#884).
