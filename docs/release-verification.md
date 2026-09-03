# Release Verification Runbook

Validate that a tagged release can be consumed by a fresh host with no
pre-existing state — the "pull-only" smoke path that proves GHCR packages
are public, the generator emits images, and the dispatcher remains unblocked.

**Target**: Fresh LXD container / VM with minimal host deps.
**Time budget**: <5 min end-to-end (automated by `tests/release-smoke.sh`).

---

## Prerequisites (on the fresh host)

Install the following before proceeding:

```bash
# Ubuntu 24.04 / Debian 12 base
apt-get update && apt-get install -y \
  docker.io jq curl git tmux postgresql-client python3 lxd
lxd init --default
```

No `disinto` binary or git clone is expected at this point — the test
downloads the tagged release from the public mirror.

---

## Step 1 — Clone the tagged release

```bash
export VERSION="v0.3.0"  # adjust to the release under test
git clone --branch "v${VERSION}" \
  https://codeberg.org/johba/disinto /tmp/disinto-verify
cd /tmp/disinto-verify
```

Assert the VERSION file matches the tag:

```bash
tag_version="${VERSION#v}"
file_version="$(cat VERSION)"
[ "$tag_version" = "$file_version" ] \
  || { echo "FAIL: VERSION mismatch — tag=$tag_version file=$file_version"; exit 1; }
```

---

## Step 2 — Bootstrap a disposable smoke project

```bash
# Use a disposable smoke repo (public, read-only clone is sufficient)
export DISINTO_IMAGE_TAG="v${VERSION}"
./bin/disinto init https://codeberg.org/disinto/example-smoke --bare --yes
```

This generates `projects/example-smoke.toml`, a `.env` file, and a local
clone of the smoke repo.

---

## Step 3 — Start the stack

```bash
./bin/disinto up --wait
```

Wait for all containers to become healthy.

---

## Step 4 — Assert health

```bash
# docker compose ps — all services should be "healthy"
docker compose ps | grep -c healthy || { echo "FAIL: containers not healthy"; exit 1; }

# disinto status — should print expected lines
./bin/disinto status | grep -q "Forgejo"  || echo "WARN: Forgejo not detected"
./bin/disinto status | grep -q "Woodpecker" || echo "WARN: Woodpecker not detected"

# Agent polling — heartbeat within 5 min
sleep 300
docker compose logs agents 2>&1 | grep -q "heartbeat" \
  || echo "WARN: no agent heartbeat within 5 min"
```

---

## Step 5 — Teardown

```bash
./bin/disinto down
lxc delete disinto-verify --force  # if running inside LXD
rm -rf /tmp/disinto-verify
```

---

## Failure modes and what they mean

| Symptom | Likely cause | Fix |
|---|---|---|
| `denied: your request is not authorized` | GHCR packages not public | Run `ghcr-publish` action (see #606) |
| `generator emitted build:` | Generator still build-locked | Check #601 dispatcher fix landed |
| `missing secret` | Vault KV or Woodpecker secrets not seeded | Run #603/#604 seeders |
| `VERSION mismatch` | Release tag not synced with tree | Fix VERSION file, re-tag |
| Agent never polls | claude auth / OAuth not configured | One-time `claude login` on host |

---

## Nomad backend (`tests/release-smoke-nomad.sh`)

The steps above only exercise the docker-compose backend. The nomad
backend (cluster-up + Vault + `nomad job run`) gets the same
fresh-host treatment via `tests/release-smoke-nomad.sh`, which
`tests/release-smoke.sh` appends to its run with a combined summary.

```bash
VERSION=v0.3.0 bash tests/release-smoke-nomad.sh
```

### Stage A — plan validation (always runs, no host mutation)

Clones the tag into a scratch dir (or, in CI, validates the checkout in
place via `SRC_DIR=$PWD`), then runs:

```bash
./bin/disinto init placeholder/repo --backend=nomad --with forgejo \
  --import-env <scratch-env> --dry-run
```

and asserts:

- exit 0;
- the plan contains all five sections: **Cluster-up dry-run**,
  **Vault policies dry-run**, **Vault auth dry-run**, **Vault import
  dry-run**, **Deploy services dry-run**;
- every `.sh`/`.hcl` path under the clone that the plan references
  (e.g. `lib/init/nomad/*.sh`, `nomad/jobs/*.hcl`) exists in the tree,
  plus explicit checks that `tools/vault-apply-policies.sh` and
  `tools/vault-import.sh` are present and executable.

No Nomad, Vault, or LXD state is touched — the plan is computed, never
executed. This is the stage CI runs (`.woodpecker/smoke-init.yml`,
step `release-smoke-nomad`).

### Stage B — fresh-LXC init (operator-gated)

Gated on `SCRATCH_LXC_NAME`; without it (and without LXD on the CI
runner) the stage prints `SKIP` and the script still exits 0. To run
the real deploy on an LXD host:

1. Provision a scratch container image (default `images:ubuntu/24.04`)
   and a free container name, e.g. `disinto-smoke-nomad`. The script
   refuses to run if the name already exists.
2. Run:

   ```bash
   SCRATCH_LXC_NAME=disinto-smoke-nomad VERSION=v0.3.0 \
     bash tests/release-smoke-nomad.sh
   ```

   The script `lxc launch`es the container, installs git/curl inside
   it, clones the tag, and runs
   `./bin/disinto init placeholder/repo --backend=nomad --with forgejo`
   inside the container (log:
   `/tmp/disinto-smoke-nomad-init-<ref>.log`).
3. It then polls `nomad job status forgejo` inside the container for
   up to 10 minutes (running + healthy) and curls
   `http://127.0.0.1:3000/api/v1/version`.
4. Teardown is automatic: `lxc delete <name> --force`. The scratch
   clone under `/tmp` is removed too.

Record the Stage B result in the release notes / acceptance commit —
Stage A alone does not prove a tagged release actually boots Nomad.

---

## Automation

The script `tests/release-smoke.sh` automates this runbook and prints
`PASS`/`FAIL` with stage markers (`[1/5]`, `[2/5]`, …). Run it manually
post-release:

```bash
VERSION=v0.3.0 bash tests/release-smoke.sh
```

It runs the compose stages above, then hands off to
`tests/release-smoke-nomad.sh` for the Nomad backend (Stage A always;
Stage B only if `SCRATCH_LXC_NAME` is set), and prints a combined
`RELEASE SMOKE: PASSED/FAILED` summary.

CI coverage: `.woodpecker/smoke-init.yml` triggers on changes to
`bin/disinto`, `lib/init/nomad/**`, `tests/**`, and runs
`tests/release-smoke-nomad.sh` with `SRC_DIR` — i.e. Nomad Stage A is
tested on every relevant PR; Stage B stays operator-gated.
