<!-- last-reviewed: 2a7ae0b7eae5979b2c53e3bd1c4280dfdc9df785 -->
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
  adds `*.hcl` job files for forgejo, woodpecker, agents, caddy,
  etc. When that lands, jobspecs will live in `nomad/jobs/` and each
  will get its own header comment pointing to the `host_volume` names
  it consumes (`volume = "forgejo-data"`, etc. — declared in
  `client.hcl`).
- **TLS, ACLs, gossip encryption.** Deliberately absent in Step 0 —
  factory traffic stays on localhost. These land in later migration
  steps alongside multi-node support.

## Adding a jobspec (Step 1 and later)

1. Drop a file in `nomad/jobs/<service>.hcl`. The `.hcl` suffix is
   load-bearing: `.woodpecker/nomad-validate.yml` globs on exactly that
   suffix to auto-pick up new jobspecs (see step 2 in "How CI validates
   these files" below). Anything else in `nomad/jobs/` is silently
   skipped by CI.
2. If it needs persistent state, reference a `host_volume` already
   declared in `client.hcl` — *don't* add ad-hoc host paths in the
   jobspec. If a new volume is needed, add it to **both**:
     - `nomad/client.hcl` — the `host_volume "<name>" { path = … }` block
     - `lib/init/nomad/cluster-up.sh` — the `HOST_VOLUME_DIRS` array
   The two must stay in sync or nomad fingerprinting will fail and the
   node stays in "initializing". Note that offline `nomad job validate`
   will NOT catch a typo in the jobspec's `source = "..."` against the
   client.hcl host_volume list (see step 2 below) — the scheduler
   rejects the mismatch at placement time instead.
3. Pin image tags — `image = "forgejo/forgejo:1.22.5"`, not `:latest`.
4. No pipeline edit required — step 2 of `nomad-validate.yml` globs
   over `nomad/jobs/*.hcl` and validates every match. Just make sure
   the existing `nomad/**` trigger path still covers your file (it
   does for anything under `nomad/jobs/`).

## How CI validates these files

`.woodpecker/nomad-validate.yml` runs on every PR that touches `nomad/`
(including `nomad/jobs/`), `lib/init/nomad/`, or `bin/disinto`. Five
fail-closed steps:

1. **`nomad config validate nomad/server.hcl nomad/client.hcl`**
   — parses the HCL, fails on unknown blocks, bad port ranges, invalid
   driver config. Vault HCL is excluded (different tool). Jobspecs are
   excluded too — agent-config and jobspec are disjoint HCL grammars;
   running this step on a jobspec rejects it with "unknown block 'job'".
2. **`nomad job validate nomad/jobs/*.hcl`** (loop, one call per file)
   — parses each jobspec's HCL, fails on unknown stanzas, missing
   required fields, wrong value types, invalid driver config. Runs
   offline (no Nomad server needed) so CI exit 0 ≠ "this will schedule
   successfully"; it means "the HCL itself is well-formed". What this
   step does NOT catch:
     - cross-file references (`source = "forgejo-data"` typo against the
       `host_volume` list in `client.hcl`) — that's a scheduling-time
       check on the live cluster, not validate-time.
     - image reachability — `image = "codeberg.org/forgejo/forgejo:11.0"`
       is accepted even if the registry is down or the tag is wrong.
   New jobspecs are picked up automatically by the glob — no pipeline
   edit needed as long as the file is named `<name>.hcl`.
3. **`vault operator diagnose -config=nomad/vault.hcl -skip=storage -skip=listener`**
   — Vault's equivalent syntax + schema check. `-skip=storage/listener`
   disables the runtime checks (CI containers don't have
   `/var/lib/vault/data` or port 8200). Exit 2 (advisory warnings only,
   e.g. TLS-disabled listener) is tolerated; exit 1 blocks merge.
4. **`shellcheck --severity=warning lib/init/nomad/*.sh bin/disinto`**
   — all init/dispatcher shell clean. `bin/disinto` has no `.sh`
   extension so the repo-wide shellcheck in `.woodpecker/ci.yml` skips
   it — this is the one place it gets checked.
5. **`bats tests/disinto-init-nomad.bats`**
   — exercises the dispatcher: `disinto init --backend=nomad --dry-run`,
   `… --empty --dry-run`, and the `--backend=docker` regression guard.

If a PR breaks `nomad/server.hcl` (e.g. typo in a block name), step 1
fails with a clear error; if it breaks a jobspec (e.g. misspells
`task` as `tsak`, or adds a `volume` stanza without a `source`), step
2 fails instead. The fix makes it pass. PRs that don't touch any of
the trigger paths skip this pipeline entirely.

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
