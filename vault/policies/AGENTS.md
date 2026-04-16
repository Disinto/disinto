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

## What this directory does NOT own

- **Attaching policies to Nomad jobs.** That's S2.4 (#882) via the
  jobspec `template { vault { policies = […] } }` stanza.
- **Enabling JWT auth + Nomad workload identity roles.** That's S2.3
  (#881).
- **Writing the secret values themselves.** That's S2.2 (#880) via
  `tools/vault-import.sh`.
- **CI policy fmt + validate + roles.yaml check.** That's S2.6 (#884).
