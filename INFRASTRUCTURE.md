# Infrastructure

How the disinto factory box (`disinto-nomad-box`) is bootstrapped from a clean
LXC, what host-side state must exist before any Nomad jobspec will place, and
how to sync repo changes onto a live box without forgetting a step.

This doc is the operator-side complement to the per-jobspec details in
[`nomad/AGENTS.md`](nomad/AGENTS.md). If you are about to rebuild the box, or
have just hand-edited `/etc/nomad.d/`, read this first.

---

## Single-source-of-truth contract

The Nomad agent on the factory box reads `/etc/nomad.d/*.hcl`. Those files
are NOT the source of truth — the in-repo files under `nomad/` are. The
flow is one-way:

```
nomad/server.hcl  ──┐
                    ├─→  /etc/nomad.d/  ──→  nomad agent
nomad/client.hcl  ──┘    (copied by cluster-up.sh or sync script)
```

Hand-edits to `/etc/nomad.d/` survive only until the next clean rebuild —
or the next time someone runs `tools/sync-nomad-client-config.sh`. If you
need a change to stick, it goes in the repo first.

---

## Bootstrap sequence (clean box)

On a fresh Ubuntu 24.04 LXC, the orchestrator
[`lib/init/nomad/cluster-up.sh`](lib/init/nomad/cluster-up.sh) runs all nine
steps idempotently:

1. **Install Nomad + Vault binaries + Docker daemon.**
   `lib/init/nomad/install.sh` — pinned versions from
   `NOMAD_VERSION` / `VAULT_VERSION`.

2. **Write `nomad.service`** (enabled, not started).
   `lib/init/nomad/systemd-nomad.sh`.

3. **Write `vault.service` + `vault.hcl`** (enabled, not started).
   `lib/init/nomad/systemd-vault.sh`.

4. **Create host-volume directories under `/srv/disinto/`.**
   The `HOST_VOLUME_DIRS` array in `cluster-up.sh` MUST match every
   `host_volume "..." { path = ... }` block in `nomad/client.hcl`. A new
   volume needs to be added to BOTH places; the two-place contract is
   spelled out in [`nomad/AGENTS.md`](nomad/AGENTS.md#adding-a-jobspec-step-1-and-later)
   too.

5. **Copy `nomad/server.hcl` + `nomad/client.hcl` into `/etc/nomad.d/`.**
   `install_file_if_differs` — content-identical files are a no-op so
   re-running cluster-up.sh on a healthy box logs `unchanged:` and moves on.

6. **First-run `vault operator init` + persist unseal/root keys.**
   `lib/init/nomad/vault-init.sh`.

7. **Start vault.service + poll until unsealed.**

8. **Start nomad.service + poll until ≥1 node ready + docker driver healthy.**

9. **Write `/etc/profile.d/disinto-nomad.sh`** so interactive shells get
   `VAULT_ADDR` + `NOMAD_ADDR`.

After step 9, the empty cluster is up — no jobs deployed. Step-1+ issues
layer job deployment on top.

```bash
# On a fresh LXC:
sudo lib/init/nomad/cluster-up.sh
# or, to see the step list without doing anything:
sudo lib/init/nomad/cluster-up.sh --dry-run
```

---

## host_volume + plugin invariants

These declarations in `nomad/client.hcl` are the contract every jobspec
mounts against. A mismatch between this file and the live agent silently
breaks job placement (`missing host volume "X"`).

### Required host_volume blocks

Every name below MUST exist as a `host_volume "<name>" { path = "..." }`
stanza in `nomad/client.hcl`, AND its host path MUST be created by step 4
of the bootstrap sequence.

| Name                          | Host path                              | Used by                            |
|-------------------------------|----------------------------------------|------------------------------------|
| `forgejo-data`                | `/srv/disinto/forgejo-data`            | `nomad/jobs/forgejo.hcl`           |
| `woodpecker-data`             | `/srv/disinto/woodpecker-data`         | `nomad/jobs/woodpecker-server.hcl` |
| `agent-data`                  | `/srv/disinto/agent-data`              | `nomad/jobs/agents.hcl`            |
| `project-repos`               | `/srv/disinto/project-repos`           | `nomad/jobs/agents.hcl`            |
| `caddy-data`                  | `/srv/disinto/caddy-data`              | `nomad/jobs/edge.hcl` (caddy)      |
| `site-content`                | `/srv/disinto/docker` (ro)             | `nomad/jobs/staging.hcl`           |
| `chat-history`                | `/srv/disinto/chat-history`            | `nomad/jobs/edge.hcl` (chat)       |
| `ops-repo`                    | `/srv/disinto/ops-repo`                | `nomad/jobs/edge.hcl` (dispatcher) |
| `agent-data-opus-supervisor`  | `/srv/disinto/agent-data-opus-supervisor` | `nomad/jobs/agents-supervisor-opus.hcl` |
| `claude-creds`                | `/srv/disinto/claude-creds` (ro)       | `nomad/jobs/agents-supervisor-opus.hcl` |
| `snapshot-state`              | `/srv/disinto/snapshot-state`          | `nomad/jobs/edge.hcl` (snapshot daemon, caddy ro mount) |
| `threads-state`               | `/srv/disinto/threads-state`           | `nomad/jobs/edge.hcl` (caddy ro mount), `nomad/jobs/edge-threads-gc.hcl` (rw) |

The `snapshot-state` and `threads-state` host paths use `/srv/disinto/`
(not `/var/lib/disinto/`) because the `raw_exec` snapshot daemon writes
directly to the host path (`SNAPSHOT_PATH=/srv/disinto/snapshot-state/state.json`
in `nomad/jobs/edge.hcl`), bypassing the Nomad volume_mount layer.
Container consumers see this path remapped to `/var/lib/disinto/snapshot`
or `/var/lib/disinto/threads` via the `volume_mount { destination = ... }`
inside the jobspec — the in-container path stays stable for code that
reads it (`docker/chat/server.py`, `docker/edge/chat-skills/factory-state/`,
`bin/snapshot-*.sh`, etc.).

### Required plugin blocks

| Plugin     | Why                                                                  |
|------------|----------------------------------------------------------------------|
| `docker`   | Default driver for every long-running service job. `allow_privileged = true` is required by `nomad/jobs/woodpecker-agent.hcl` (Docker-in-Docker). |
| `raw_exec` | `nomad/jobs/edge.hcl`'s snapshot task runs on the host (no container) — needs `enabled = true` on the client. Without this block the snapshot daemon will not place. |

If the live `/etc/nomad.d/client.hcl` is missing any of the above, a
`nomad job run` of the affected jobspec will fail at placement time with
either `missing host volume "X"` or `missing drivers`. The CI step
`nomad config validate` (`.woodpecker/nomad-validate.yml`) catches HCL
syntax errors but not `host_volume` / `plugin` *absence* — that is a live
cluster check.

---

## Syncing repo changes onto a live box

After editing `nomad/client.hcl` (adding a `host_volume`, enabling a
plugin, etc.), don't hand-edit `/etc/nomad.d/client.hcl`. Run:

```bash
sudo tools/sync-nomad-client-config.sh             # diff + copy + restart
sudo tools/sync-nomad-client-config.sh --dry-run   # diff only, no changes
sudo tools/sync-nomad-client-config.sh --with-server  # also sync server.hcl
```

The script:

1. Diffs each in-repo file against `/etc/nomad.d/`. No-op when in sync.
2. Runs `nomad config validate` against the new files BEFORE touching
   the live config — a syntax error aborts before the agent gets killed.
3. Copies into `/etc/nomad.d/` (root:root, 0644).
4. **Restarts** `nomad.service` (host_volume + plugin changes require a
   full restart, not `nomad agent reload` / SIGHUP — the contract is in
   the script header).
5. Polls `nomad node status -self -verbose` until the agent reports
   `Host Volumes` and at least one ready node.

If the post-restart poll fails the script exits 2 with a `systemctl status`
dump.

### Verifying the live state

```bash
# Compare the in-repo client.hcl against the live one:
diff -u /etc/nomad.d/client.hcl nomad/client.hcl

# List host_volumes the agent actually fingerprinted:
nomad node status -self -verbose | sed -n '/^Host Volumes/,/^$/p'

# Confirm raw_exec is enabled:
nomad node status -self -verbose | grep -E '^driver\.raw_exec'
```

The `nomad node status -self -verbose` `Host Volumes` set MUST match the
`host_volume` declarations in `nomad/client.hcl` after a successful sync.

---

## Recovering a wiped box

A clean rebuild loses everything under `/etc/nomad.d/`, `/srv/disinto/*`,
and the Vault data dir. To reproduce the live setup from scratch:

```bash
# 1. Bootstrap the empty cluster:
sudo lib/init/nomad/cluster-up.sh

# 2. (Optional) Verify host_volumes match the repo:
sudo tools/sync-nomad-client-config.sh --dry-run

# 3. Deploy services in dependency order (Step-1+ jobs):
disinto init --backend=nomad --import-env .env --with edge
```

If `disinto init` fails with `missing host volume "X"`, the gap is between
`nomad/client.hcl` and `lib/init/nomad/cluster-up.sh`'s `HOST_VOLUME_DIRS`
array — fix both, send a PR, re-run `cluster-up.sh`.

---

## Related

- [`nomad/AGENTS.md`](nomad/AGENTS.md) — per-jobspec ownership + CI validation contract.
- [`docs/nomad-cutover-runbook.md`](docs/nomad-cutover-runbook.md) — full cutover procedure (dev-box → nomad-box).
- [`docs/nomad-migration.md`](docs/nomad-migration.md) — step breakdown (S0–S5).
- `lib/init/nomad/cluster-up.sh` — the bootstrap orchestrator referenced above.
- `tools/sync-nomad-client-config.sh` — incremental sync script for `/etc/nomad.d/`.
