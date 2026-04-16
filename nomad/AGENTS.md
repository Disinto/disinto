# nomad/ — Agent Instructions

Nomad + Vault HCL for the factory's single-node cluster. These files are
the source of truth that `lib/init/nomad/cluster-up.sh` copies onto a
factory box under `/etc/nomad.d/` and `/etc/vault.d/` at init time.

This directory is part of the **Nomad+Vault migration (Step 0)** —
see issues #821–#825 for the step breakdown. Jobspecs land in Step 1.

## What lives here

| File | Deployed to | Owned by |
|---|---|---|
| `server.hcl` | `/etc/nomad.d/server.hcl` | agent role, bind, ports, `data_dir` (S0.2) |
| `client.hcl` | `/etc/nomad.d/client.hcl` | Docker driver cfg + `host_volume` declarations (S0.2) |
| `vault.hcl`  | `/etc/vault.d/vault.hcl`  | Vault storage, listener, UI, `disable_mlock` (S0.3) |

Nomad auto-merges every `*.hcl` under `-config=/etc/nomad.d/`, so the
split between `server.hcl` and `client.hcl` is for readability, not
semantics. The top-of-file header in each config documents which blocks
it owns.

## What does NOT live here yet

- **Jobspecs.** Step 0 brings up an *empty* cluster. Step 1 (and later)
  adds `*.nomad.hcl` job files for forgejo, woodpecker, agents, caddy,
  etc. When that lands, jobspecs will live in `nomad/jobs/` and each
  will get its own header comment pointing to the `host_volume` names
  it consumes (`volume = "forgejo-data"`, etc. — declared in
  `client.hcl`).
- **TLS, ACLs, gossip encryption.** Deliberately absent in Step 0 —
  factory traffic stays on localhost. These land in later migration
  steps alongside multi-node support.

## Adding a jobspec (Step 1 and later)

1. Drop a file in `nomad/jobs/<service>.nomad.hcl`.
2. If it needs persistent state, reference a `host_volume` already
   declared in `client.hcl` — *don't* add ad-hoc host paths in the
   jobspec. If a new volume is needed, add it to **both**:
     - `nomad/client.hcl` — the `host_volume "<name>" { path = … }` block
     - `lib/init/nomad/cluster-up.sh` — the `HOST_VOLUME_DIRS` array
   The two must stay in sync or nomad fingerprinting will fail and the
   node stays in "initializing".
3. Pin image tags — `image = "forgejo/forgejo:1.22.5"`, not `:latest`.
4. Add the jobspec path to `.woodpecker/nomad-validate.yml`'s trigger
   list so CI validates it.

## How CI validates these files

`.woodpecker/nomad-validate.yml` runs on every PR that touches `nomad/`,
`lib/init/nomad/`, or `bin/disinto`. Four fail-closed steps:

1. **`nomad config validate nomad/server.hcl nomad/client.hcl`**
   — parses the HCL, fails on unknown blocks, bad port ranges, invalid
   driver config. Vault HCL is excluded (different tool).
2. **`vault operator diagnose -config=nomad/vault.hcl -skip=storage -skip=listener`**
   — Vault's equivalent syntax + schema check. `-skip=storage/listener`
   disables the runtime checks (CI containers don't have
   `/var/lib/vault/data` or port 8200).
3. **`shellcheck --severity=warning lib/init/nomad/*.sh bin/disinto`**
   — all init/dispatcher shell clean. `bin/disinto` has no `.sh`
   extension so the repo-wide shellcheck in `.woodpecker/ci.yml` skips
   it — this is the one place it gets checked.
4. **`bats tests/disinto-init-nomad.bats`**
   — exercises the dispatcher: `disinto init --backend=nomad --dry-run`,
   `… --empty --dry-run`, and the `--backend=docker` regression guard.

If a PR breaks `nomad/server.hcl` (e.g. typo in a block name), step 1
fails with a clear error; the fix makes it pass. PRs that don't touch
any of the trigger paths skip this pipeline entirely.

## Version pinning

Nomad + Vault versions are pinned in **two** places — bumping one
without the other is a CI-caught drift:

- `lib/init/nomad/install.sh` — the apt-installed versions on factory
  boxes (`NOMAD_VERSION`, `VAULT_VERSION`).
- `.woodpecker/nomad-validate.yml` — the `hashicorp/nomad:…` and
  `hashicorp/vault:…` image tags used for static validation.

Bump both in the same PR. The CI pipeline will fail if the pinned
image's `config validate` rejects syntax the installed runtime would
accept (or vice versa).

## Related

- `lib/init/nomad/` — installer + systemd units + cluster-up orchestrator.
- `.woodpecker/nomad-validate.yml` — this directory's CI pipeline.
- Top-of-file headers in `server.hcl` / `client.hcl` / `vault.hcl`
  document the per-file ownership contract.
