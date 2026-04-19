<!-- last-reviewed: 5ba18c8f80da6e3e574823e39e5aa760731c1705 -->
# nomad/ — Agent Instructions

Nomad + Vault HCL for the factory's single-node cluster. These files are
the source of truth that `lib/init/nomad/cluster-up.sh` copies onto a
factory box under `/etc/nomad.d/` and `/etc/vault.d/` at init time.

This directory covers the **Nomad+Vault migration (Steps 0–5)** —
see issues #821–#992 for the step breakdown.

## What lives here

| File/Dir | Deployed to | Owned by |
|---|---|---|
| `server.hcl` | `/etc/nomad.d/server.hcl` | agent role, bind, ports, `data_dir` (S0.2) |
| `client.hcl` | `/etc/nomad.d/client.hcl` | Docker driver cfg + `host_volume` declarations (S0.2); `allow_privileged = true` for woodpecker-agent Docker-in-Docker (S3-fix-5, #961) |
| `vault.hcl`  | `/etc/vault.d/vault.hcl`  | Vault storage, listener, UI, `disable_mlock` (S0.3) |
| `jobs/forgejo.hcl` | submitted via `lib/init/nomad/deploy.sh` | Forgejo job; reads creds from Vault via consul-template stanza (S2.4) |
| `jobs/woodpecker-server.hcl` | submitted via `lib/init/nomad/deploy.sh` | Woodpecker CI server; host networking, Vault KV for `WOODPECKER_AGENT_SECRET` + Forgejo OAuth creds (S3.1) |
| `jobs/woodpecker-agent.hcl` | submitted via `lib/init/nomad/deploy.sh` | Woodpecker CI agent; host networking, `docker.sock` mount, Vault KV for `WOODPECKER_AGENT_SECRET`; `WOODPECKER_SERVER` uses `${attr.unique.network.ip-address}:9000` (Nomad interpolation) — port binds to LXC alloc IP, not localhost (S3.2, S3-fix-6, #964) |
| `jobs/agents.hcl` | submitted via `lib/init/nomad/deploy.sh` | All 7 agent roles (dev, review, gardener, planner, predictor, supervisor, architect) + llama variant; Vault-templated bot tokens via `service-agents` policy; `force_pull = false` — image is built locally by `bin/disinto --with agents`, no registry (S4.1, S4-fix-2, S4-fix-5, #955, #972, #978) |
| `jobs/staging.hcl` | submitted via `lib/init/nomad/deploy.sh` | Caddy file-server mounting `docker/` as `/srv/site:ro`; no Vault integration; **dynamic host port** (no static 80 — edge owns 80/443, collision fixed in S5-fix-7 #1018); edge discovers via Nomad service registration (S5.2, #989) |
| `jobs/chat.hcl` | submitted via `lib/init/nomad/deploy.sh` | Claude chat UI; custom `disinto/chat:local` image; sandbox hardening (cap_drop ALL, **tmpfs via mount block** not `tmpfs=` arg — S5-fix-5 #1012, pids_limit 128); Vault-templated OAuth secrets via `service-chat` policy (S5.2, #989) |
| `jobs/edge.hcl` | submitted via `lib/init/nomad/deploy.sh` | Caddy reverse proxy + dispatcher sidecar; routes /forge, /woodpecker, /staging, /chat; uses `disinto/edge:local` image built by `bin/disinto --with edge`; **both Caddy and dispatcher tasks use `network_mode = "host"`** — upstreams are `127.0.0.1:<port>` (forgejo :3000, woodpecker :8000, chat :8080), not Docker hostnames (#1031, #1034); `FORGE_URL` rendered via Nomad service discovery template (not static env) to handle bridge vs. host network differences (#1034); dispatcher Vault secret path changed to `kv/data/disinto/shared/ops-repo` (#1041); Vault-templated ops-repo creds via `service-dispatcher` policy (S5.1, #988) |

Nomad auto-merges every `*.hcl` under `-config=/etc/nomad.d/`, so the
split between `server.hcl` and `client.hcl` is for readability, not
semantics. The top-of-file header in each config documents which blocks
it owns.

## Vault ACL policies

`vault/policies/` holds one `.hcl` file per Vault policy; see
[`vault/policies/AGENTS.md`](../vault/policies/AGENTS.md) for the naming
convention, KV path summary, and JWT-auth role bindings (S2.1/S2.3).

## Not yet implemented

- **TLS, ACLs, gossip encryption** — deliberately absent for now; land
  alongside multi-node support.

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
(including `nomad/jobs/`), `lib/init/nomad/`, `bin/disinto`,
`vault/policies/`, or `vault/roles.yaml`. Eight fail-closed steps:

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
4. **`vault policy fmt` idempotence check on every `vault/policies/*.hcl`**
   (S2.6) — `vault policy fmt` has no `-check` flag in 1.18.5, so the
   step copies each file to `/tmp`, runs `vault policy fmt` on the copy,
   and diffs against the original. Any non-empty diff means the
   committed file would be rewritten by `fmt` and the step fails — the
   author is pointed at `vault policy fmt <file>` to heal the drift.
5. **`vault policy write`-based validation against an inline dev-mode Vault**
   (S2.6) — Vault 1.18.5 has no offline `policy validate` subcommand;
   the CI step starts a dev-mode server, loops `vault policy write
   <basename> <file>` over each `vault/policies/*.hcl`, and aggregates
   failures so one CI run surfaces every broken policy. The server is
   ephemeral and torn down on step exit — no persistence, no real
   secrets. Catches unknown capability names (e.g. `"frobnicate"`),
   malformed `path` blocks, and other semantic errors `fmt` does not.
6. **`vault/roles.yaml` validator** (S2.6) — yamllint + a PyYAML-based
   check that every role's `policy:` field matches a basename under
   `vault/policies/`, and that every role entry carries all four
   required fields (`name`, `policy`, `namespace`, `job_id`). Drift
   between the two directories is a scheduling-time "permission denied"
   in production; this step turns it into a CI failure at PR time.
7. **`shellcheck --severity=warning lib/init/nomad/*.sh bin/disinto`**
   — all init/dispatcher shell clean. `bin/disinto` has no `.sh`
   extension so the repo-wide shellcheck in `.woodpecker/ci.yml` skips
   it — this is the one place it gets checked.
8. **`bats tests/disinto-init-nomad.bats`**
   — exercises the dispatcher: `disinto init --backend=nomad --dry-run`,
   `… --empty --dry-run`, and the `--backend=docker` regression guard.

**Secret-scan coverage.** Policy HCL files under `vault/policies/` are
already swept by the P11 secret-scan gate
(`.woodpecker/secret-scan.yml`, #798), whose `vault/**/*` trigger path
covers everything in this directory. `nomad-validate.yml` intentionally
does NOT duplicate that gate — one scanner, one source of truth.

If a PR breaks `nomad/server.hcl` (e.g. typo in a block name), step 1
fails with a clear error; if it breaks a jobspec (e.g. misspells
`task` as `tsak`, or adds a `volume` stanza without a `source`), step
2 fails; a typo in a `path "..."` block in a vault policy fails step 5
with the Vault parser's error; a `roles.yaml` entry that points at a
policy basename that does not exist fails step 6. PRs that don't touch
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
- `vault/policies/` — Vault ACL policy HCL files (S2.1); the
  `vault-policy-fmt` / `vault-policy-validate` CI steps above enforce
  their shape. See [`../vault/policies/AGENTS.md`](../vault/policies/AGENTS.md)
  for the policy lifecycle, CI enforcement details, and common failure
  modes.
- `vault/roles.yaml` — JWT-auth role → policy bindings (S2.3); the
  `vault-roles-validate` CI step above keeps it in lockstep with the
  policies directory.
- Top-of-file headers in `server.hcl` / `client.hcl` / `vault.hcl`
  document the per-file ownership contract.
