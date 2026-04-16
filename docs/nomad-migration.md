<!-- last-reviewed: (new file, S2.5 #883) -->
# Nomad+Vault migration — cutover-day runbook

`disinto init --backend=nomad` is the single entry-point that turns a fresh
LXC (with the disinto repo cloned) into a running Nomad+Vault cluster with
policies applied, JWT workload-identity auth configured, secrets imported
from the old docker stack, and services deployed.

## Cutover-day invocation

On the new LXC, as root (or an operator with NOPASSWD sudo):

```bash
# Copy the plaintext .env + sops-encrypted .env.vault.enc + age keyfile
# from the old box first (out of band — SSH, USB, whatever your ops
# procedure allows). Then:

sudo ./bin/disinto init \
  --backend=nomad \
  --import-env   /tmp/.env \
  --import-sops  /tmp/.env.vault.enc \
  --age-key      /tmp/keys.txt \
  --with         forgejo
```

This runs, in order:

1. **`lib/init/nomad/cluster-up.sh`** (S0) — installs Nomad + Vault
   binaries, writes `/etc/nomad.d/*`, initializes Vault, starts both
   services, waits for the Nomad node to become ready.
2. **`tools/vault-apply-policies.sh`** (S2.1) — syncs every
   `vault/policies/*.hcl` into Vault as an ACL policy. Idempotent.
3. **`lib/init/nomad/vault-nomad-auth.sh`** (S2.3) — enables Vault's
   JWT auth method at `jwt-nomad`, points it at Nomad's JWKS, writes
   one role per policy, reloads Nomad so jobs can exchange
   workload-identity tokens for Vault tokens. Idempotent.
4. **`tools/vault-import.sh`** (S2.2) — reads `/tmp/.env` and the
   sops-decrypted `/tmp/.env.vault.enc`, writes them to the KV paths
   matching the S2.1 policy layout (`kv/disinto/bots/*`, `kv/disinto/shared/*`,
   `kv/disinto/runner/*`). Idempotent (overwrites KV v2 data in place).
5. **`lib/init/nomad/deploy.sh forgejo`** (S1) — validates + runs the
   `nomad/jobs/forgejo.hcl` jobspec. Forgejo reads its admin creds from
   Vault via the `template` stanza (S2.4).

## Flag summary

| Flag | Meaning |
|---|---|
| `--backend=nomad` | Switch the init dispatcher to the Nomad+Vault path (instead of docker compose). |
| `--empty` | Bring the cluster up, skip policies/auth/import/deploy. Escape hatch for debugging. |
| `--with forgejo[,…]` | Deploy these services after the cluster is up. |
| `--import-env PATH` | Plaintext `.env` from the old stack. Optional. |
| `--import-sops PATH` | Sops-encrypted `.env.vault.enc` from the old stack. Requires `--age-key`. |
| `--age-key PATH` | Age keyfile used to decrypt `--import-sops`. Requires `--import-sops`. |
| `--dry-run` | Print the full plan (cluster-up + policies + auth + import + deploy) and exit. Touches nothing. |

### Flag validation

- `--import-sops` without `--age-key` → error.
- `--age-key` without `--import-sops` → error.
- `--import-env` alone (no sops) → OK (imports just the plaintext `.env`).
- `--backend=docker` with any `--import-*` flag → error.

## Idempotency

Every layer is idempotent by design. Re-running the same command on an
already-provisioned box is a no-op at every step:

- **Cluster-up:** second run detects running `nomad`/`vault` systemd
  units and state files, skips re-init.
- **Policies:** byte-for-byte compare against on-server policy text;
  "unchanged" for every untouched file.
- **Auth:** skips auth-method create if `jwt-nomad/` already enabled,
  skips config write if the JWKS + algs match, skips server.hcl write if
  the file on disk is identical to the repo copy.
- **Import:** KV v2 writes overwrite in place (same path, same keys,
  same values → no new version).
- **Deploy:** `nomad job run` is declarative; same jobspec → no new
  allocation.

## Dry-run

```bash
./bin/disinto init --backend=nomad \
  --import-env /tmp/.env \
  --import-sops /tmp/.env.vault.enc \
  --age-key /tmp/keys.txt \
  --with forgejo \
  --dry-run
```

Prints the five-section plan — cluster-up, policies, auth, import,
deploy — with every path and every argv that would be executed. No
network, no sudo, no state mutation. See
`tests/disinto-init-nomad.bats` for the exact output shape.

## No-import path

If you already have `kv/disinto/*` seeded by other means (manual
`vault kv put`, a replica, etc.), omit all three `--import-*` flags.
`disinto init --backend=nomad --with forgejo` still applies policies,
configures auth, and deploys — but skips the import step with:

```
[import] no --import-env/--import-sops — skipping; set them or seed kv/disinto/* manually before deploying secret-dependent services
```

Forgejo's template stanza will fail to render (and thus the allocation
will stall) until those KV paths exist — so either import them or seed
them first.

## Secret hygiene

- Never log a secret value. The CLI only prints paths (`--import-env`,
  `--age-key`) and KV *paths* (`kv/disinto/bots/review/token`), never
  the values themselves. `tools/vault-import.sh` is the only thing that
  reads the values, and it pipes them directly into Vault's HTTP API.
- The age keyfile must be mode 0400 — `vault-import.sh` refuses to
  source a keyfile with looser permissions.
- `VAULT_ADDR` must be localhost during import — the import tool
  refuses to run against a remote Vault, preventing accidental exposure.
