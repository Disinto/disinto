# Release Verification Runbook

Validate that a tagged release can be consumed by a fresh host with no
pre-existing state — the "pull-only" smoke path that proves GHCR packages
are public, the generator emits images, and the dispatcher remains unblocked.

**Target**: Fresh LXD container / VM with minimal host deps.
**Time budget**: <5 min end-to-end (automated by `tests/release-smoke.sh`).

> **Backends under test:** Steps 1–5 below exercise the docker-compose
> backend. The **Nomad+Vault** backend — the one the production factory and
> the planned second instance use — is covered in the "Nomad backend"
> section below (`tests/release-smoke-nomad.sh`): Stage A (plan validation)
> always runs, Stage B (fresh-LXC init) is operator-gated.
> `tests/release-smoke.sh` runs both and prints a combined summary, so a
> green release-smoke validates the Nomad path's init contract too.

---

## Cutting a release

`tools/cut-release.sh` (also `disinto cut-release`) cuts a release in one
verifiable command: bump → tag → push → wait for the CI images → verify GHCR
visibility → next steps (#1228).

```bash
# 1. Preview — prints the full plan, mutates nothing
tools/cut-release.sh 0.5.0 --dry-run

# 2. Bump + commit locally (no tag, no push). Leaves you on release/v0.5.0.
tools/cut-release.sh 0.5.0

# 3. Tag, push, wait for CI, verify visibility — the exact re-run step 2
#    prints. Run it from release/v0.5.0 (where step 2 left you): stage 1
#    accepts the release branch, stage 2 is a no-op (VERSION already
#    bumped), and stages 3-6 proceed. (--main works the same two-step way.)
tools/cut-release.sh 0.5.0 --yes
```

Stages (with `[N/6] PASS|FAIL|SKIP` markers, same convention as
`tests/release-smoke.sh`; the run exits non-zero on the first `FAIL`):

1. **Pre-flight** — clean tree; on `main`, or on `release/v0.5.0` when
   resuming a previous stage-2 run (where an already-bumped `VERSION` is
   the expected state, not an error); `VERSION` < target; no local tag
   `v0.5.0`; no unpushed commits on `main` (except the bump commit itself
   on a `--main` resume). Read-only and fail-fast.
2. **Bump** — write `VERSION=0.5.0`, commit `release: v0.5.0` on
   `release/v0.5.0` (or on `main` with `--main`). On a resume the bump is
   already committed and this stage is a no-op pass.
3. **Tag + push** — annotated tag `v0.5.0`, push the tag and the branch.
   The tag push triggers `.woodpecker/publish-images.yml`, which publishes
   `agents`, `reproduce`, `edge`, `research` as `v0.5.0` and `latest`.
4. **Wait CI** — poll `https://ghcr.io/v2/disinto/<img>/manifests/v0.5.0`
   (scoped anonymous token per image) until it returns 200 for all four
   images; 20 min timeout, 30 s backoff. On timeout: `FAIL` with a Woodpecker
   pipeline hint (set `WOODPECKER_SERVER` for the exact URL).
5. **Visibility** — the anonymous token exchange
   (`GET https://ghcr.io/token?scope=repository:disinto/<img>:pull`, no
   auth) must succeed for every image. A denial (HTTP 401) fails the run
   with the exact remediation: GitHub → Packages → `disinto/<img>` →
   Settings → Visibility → Public (#606). An unreachable registry (curl
   code 000 — ghcr.io down or no network) fails with a network diagnostic
   instead, so a connectivity outage is not misread as a visibility
   problem.
6. **Next steps** — run `tests/release-smoke.sh` (the compose + Nomad
   stages below) and record the result.

Without `--yes`, the run stops after stage 2 (bump committed locally on
`release/v0.5.0`, nothing tagged or pushed) and prints the remaining plan
plus the exact re-run. The re-run **resumes** from the branch stage 2
left — stage 1 accepts `release/v0.5.0` and stage 2 becomes a no-op, so
the two-step flow above always works (the same holds for `--main`, which
resumes on `main` itself). `--dry-run` stops before stage 2 and prints the
full plan (a resume plan when the bump is already committed). `--skip-wait`
skips stage 4 only (visibility still runs).

Env overrides (used by `tests/cut-release.bats`): `GHCR_REGISTRY`,
`GHCR_OWNER`, `CUT_RELEASE_IMAGES`, `WAIT_TIMEOUT_SECS`,
`POLL_INTERVAL_SECS`, `PRIMARY_BRANCH`, `CUT_RELEASE_REMOTE`,
`WOODPECKER_SERVER`, `VERSION_FILE`.

After a successful cut, continue with this runbook:

```bash
VERSION=v0.5.0 bash tests/release-smoke.sh
```

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

## Nomad backend (`tests/release-smoke-nomad.sh`)

The steps above only exercise the docker-compose backend. The Nomad+Vault
backend (cluster-up + Vault + `nomad job run`) gets the same fresh-host
treatment via `tests/release-smoke-nomad.sh`, which `tests/release-smoke.sh`
appends to its run with a combined summary.

```bash
VERSION=v0.3.0 bash tests/release-smoke-nomad.sh      # tag
SRC_DIR="$PWD" bash tests/release-smoke-nomad.sh      # validate a checkout in place (CI)
```

### Stage A — plan validation (always runs, no host mutation)

Clones the tag into a scratch dir (or, with `SRC_DIR`, validates the
checkout in place), then runs:

```bash
./bin/disinto init placeholder/repo --backend=nomad --with forgejo \
  --import-env <scratch-env> --dry-run
```

and asserts:

- exit 0;
- the plan contains all five sections: **Cluster-up dry-run**,
  **Vault policies dry-run**, **Vault auth dry-run**, **Vault import
  dry-run**, **Deploy services dry-run**;
- every `.sh`/`.hcl` path under the tree that the plan references exists in
  the tree (e.g. `lib/init/nomad/*.sh`, `nomad/jobs/*.hcl`);
- `tools/vault-apply-policies.sh` and `tools/vault-import.sh` are present
  and executable, and `vault/policies/` holds policy `.hcl` files.

No Nomad, Vault, or LXD state is touched — the plan is computed, never
executed. This is the stage CI runs (`.woodpecker/smoke-init.yml`, step
`release-smoke-nomad`, with `SRC_DIR` on the PR checkout).

### Stage B — fresh-LXC init (operator-gated)

Gated on `SCRATCH_LXC_NAME`; without it (and without LXD on the CI runner)
the stage prints `SKIP` and the script still exits 0. One-time operator
procedure on an LXD host:

1. Pick a free container name (the script refuses to run if it already
   exists) and an image (default `images:ubuntu/24.04`), e.g.
   `disinto-smoke-nomad`.
2. Run:

   ```bash
   SCRATCH_LXC_NAME=disinto-smoke-nomad VERSION=v0.3.0 \
     bash tests/release-smoke-nomad.sh
   ```

   The script `lxc launch`es the container, installs git/curl/sudo, clones
   the tag into `/root/disinto`, and runs
   `sudo ./bin/disinto init placeholder/repo --backend=nomad --with
   forgejo` inside it (log:
   `/tmp/disinto-smoke-nomad-init-<ref>.log`). For a full deploy, pass the
   import flags via
   `NOMAD_INIT_EXTRA_ARGS="--import-env /root/.env --age-key /root/keys.txt"`
   after copying the secret files into the container — without the
   `kv/disinto/*` data, Forgejo's template stanza cannot render and the job
   never reaches `running` (see the flag table in
   `docs/nomad-migration.md`).
3. It then polls `nomad job status -json forgejo` for up to 10 minutes
   (job `running`, no latest-version allocation off `running`) and curls
   `http://127.0.0.1:3000/api/v1/version`.
4. Teardown is automatic: `lxc delete <name> --force`, plus the scratch
   clone under `/tmp`.

Record the Stage B result in the acceptance commit / release notes —
Stage A alone does not prove a tagged release actually boots Nomad+Vault.

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

## Automation

The script `tests/release-smoke.sh` automates the compose runbook above,
then hands off to `tests/release-smoke-nomad.sh` for the Nomad backend
(Stage A always; Stage B only if `SCRATCH_LXC_NAME` is set), and prints a
combined `RELEASE SMOKE: PASSED/FAILED` summary. Both use `PASS`/`FAIL`/
`SKIP` stage markers (`[1/5]`, `[2/5]`, …). Run it manually post-release:

```bash
VERSION=v0.3.0 bash tests/release-smoke.sh
```

CI coverage: `.woodpecker/smoke-init.yml` triggers on changes to
`bin/disinto`, `lib/init/nomad/**`, and `tests/**`, and runs
`tests/release-smoke-nomad.sh` with `SRC_DIR` against the PR checkout —
i.e. Nomad Stage A is tested on every relevant PR. Stage B (the real
fresh-LXC deploy) stays operator-gated; record its result when run.
