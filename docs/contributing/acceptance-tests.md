# Acceptance tests

Acceptance criteria must be **runnable on the live box**, not aspirational.
Every backlog issue ships a bash file under `tests/acceptance/` that, when
executed, verifies the change behaves the way the issue claims it does.

## Why this matters

Two consecutive sprints shipped work that passed acceptance criteria as written
but did not survive contact with the live data path. The pattern was consistent
enough to be the process, not the bug:

- Agents pattern-match issue text into code that *looks like* the requested code.
- Reviewers read diffs and prose, not behavior.
- CI runs unit-test-shaped pipelines, not end-to-end on the live data path.
- Nobody runs the AC commands on the live box before closing.

The first fix was *inline shell commands in the issue body* (#839). That moved
the bar — every issue had to ship runnable steps — but inline commands rot,
can't be linted, can't be reused across issues, and require a human to run
them. So they're now files in the repo.

The convention: **every acceptance test is a bash file under
`tests/acceptance/`, executed by `tools/run-acceptance.sh <issue-number>`.**

## The convention

### Location and naming

`tests/acceptance/issue-<N>.sh` — one file per issue number. The runner
discovers tests by this exact path. A suffixed name,
`tests/acceptance/issue-<N>-<slug>.sh` (e.g.
`issue-1082-stale-worktree-registration.sh`), is also accepted: when the
plain `issue-<N>.sh` is missing, the runner falls back to the suffixed
form, provided it matches exactly one file.

### File shape

```bash
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

ac_require_cmd curl jq
ac_require_env FORGE_URL FACTORY_FORGE_PAT

ac_log "verifying snapshot has the expected collectors"
state="$(cat /srv/disinto/snapshot-state/state.json)"
ac_assert_jq '.collectors | keys | sort == ["agents","forge","inbox","nomad"]' "$state" \
  "snapshot collectors set is not {agents,forge,inbox,nomad}"

echo PASS
```

Rules:

1. **`#!/usr/bin/env bash` + `set -euo pipefail` + executable (`chmod +x`).**
2. **Exit 0 on pass, non-zero on fail.**
3. **Last stdout line is `PASS` or `FAIL: <reason>`.** stderr is for
   diagnostics; stdout drives the outcome.
4. **Read-only.** Tests query forge, nomad, the snapshot, chat/voice — they
   do not file issues, dispatch jobs, or mutate state. Reviewer-agent rejects
   mutating tests. (There is no sandbox; the rule is a convention.)
5. **Source the helpers.** `tests/lib/acceptance-helpers.sh` provides curl
   wrappers (`ac_forge_api`, `ac_nomad_api`), assertions (`ac_assert_jq`,
   `ac_assert_eq`, `ac_assert_file`), and logging (`ac_log`, `ac_fail`).
6. **Use absolute paths** for files on the live box (e.g.
   `/srv/disinto/snapshot-state/state.json`). Never rely on cwd.
7. **Reference the right artifact.** If the issue touches a state file, the
   AC must query *that* file — not a stub or a different path.
8. **Keep it focused.** A test that needs more than ~10 assertions is a sign
   the issue is too large.

### Running tests

```bash
tools/run-acceptance.sh 844                 # human-readable
tools/run-acceptance.sh --format json 844   # JSON for CI / pipelines
```

The runner:

- Locates `tests/acceptance/issue-<N>.sh`, falling back to a uniquely
  matching `issue-<N>-<slug>.sh` when the plain name is missing.
- Sources the daemon's env (`FORGE_URL`, `NOMAD_ADDR`, `FACTORY_FORGE_PAT`,
  `NOMAD_TOKEN`, …) from one of:
  - `$RUN_ACCEPTANCE_ENV_FILE` if set
  - `/etc/disinto/acceptance.env`
  - `/proc/<pid>/environ` of the running `snapshot-daemon.sh`
  - whatever is already in the current shell's env
- Captures stdout + stderr, measures duration, mirrors the test's exit code.
- Emits `--format text` (default, human-readable) or `--format json`
  (`{"issue":N,"exit":0,"result":"PASS"|"FAIL","output":"…","duration_secs":N}`).

The runner is deliberately standalone — no Woodpecker dependency. It runs from
CI, from `tools/`, or by hand.

### CI pipeline integration

**On pull requests**, CI runs the acceptance tests (see below). **After a
merge**, `.woodpecker/acceptance-tests.yml` runs no tests: it keeps the edge
deployed. On every push to `main` it:

1. **Detects** whether the merge touched the edge runtime (`docker/edge/`,
   `bin/snapshot-*.sh`, `nomad/jobs/edge.hcl`, and the paths that held chat,
   voice and threads). Other merges skip the redeploy.
2. **Advances `/opt/disinto`** to the merged commit (fast-forward only), on
   every merge: the edge runs the dispatcher and the snapshot daemon from
   that host checkout, and `agent-logs-rotate` runs scripts from it. Then,
   when the edge runtime changed, it **rebuilds + redeploys**
   `disinto/edge:local` from `/opt/disinto`, re-launches and restarts the
   nomad job, and polls `nomad job status` until the alloc is running
   (≤120s). Concurrent merges serialize via `flock` against
   `/var/lib/disinto/ci-locks/acceptance-deploy.lock`.

Until 2026-10-05 the file also tried to run each closed issue's test after
merge and comment the result. That never worked (Woodpecker pre-expanded the
variables it needed), and pre-merge testing replaced it.

**On pull requests**, the `acceptance-affected` step of `.woodpecker/ci.yml`
runs the acceptance tests the PR can break: those it adds or changes, and
those whose text names a path it changes, directly or through a
`tests/lib/` helper (`.woodpecker/acceptance-affected.sh`). Without it a test
ran only once, after its own merge, and a later change to the code it reads
broke it unseen. A test that needs the live box (the forge, nomad, the
daemon's env) carries a header line `# acceptance-ci: skip (<what it
needs>)`; CI skips it, and it is run by hand on the box with
`tools/run-acceptance.sh <N>`.

The deploy step pins to the `disinto-nomad-box` runner via `labels`, where
the lock file lives.

### Issue-body reference

The `## Acceptance test` section in the issue body should be a single line
pointing at the file:

```markdown
## Acceptance test

`tests/acceptance/issue-844.sh` — runs via `tools/run-acceptance.sh 844`.
```

Anything more than that — full command listings, expected outputs — belongs in
the file, not the issue.

### Inline-command fallback

Inline shell commands in the issue body remain a *fallback* for cases where
a CI test is genuinely infeasible — e.g. tests that need an operator to power
a device on, or to inspect a UI by eye. The default is always the file
convention.

## Positive example

```markdown
## Acceptance test

`tests/acceptance/issue-844.sh` — covers the snapshot-daemon collector
shape and the post-fix sed-over-multiline-JSON behavior.
Run via `tools/run-acceptance.sh 844`.
```

## Negative example (aspirational — do NOT use)

```markdown
## Acceptance criteria

- [ ] The daemon collects data from all agents
- [ ] The data is correct
- [ ] CI is green
```

Problems:
- "collects data" is not a command anyone can run.
- "is correct" is subjective — who decides?
- "CI is green" is a CI check, not an AC command.

## Negative example (inline, partially runnable)

```markdown
## Acceptance test

```bash
$ # Make sure the daemon is running
$ systemctl status snapshot-daemon

$ # Check the output is valid
$ cat /srv/disinto/snapshot-state/state.json | jq .
```
```

Problems:
- `systemctl status` output is not deterministic — no expected output shown.
- `jq .` succeeds on any valid JSON — no assertion on structure or content.
- It's inline. Move it to `tests/acceptance/issue-<N>.sh` and assert with
  `ac_assert_jq`.

## How reviewers check

When reviewing a PR, the reviewer checks that:

1. `tests/acceptance/issue-<N>.sh` (or a uniquely matching
   `issue-<N>-<slug>.sh`) exists for the issue's number.
2. It sources `tests/lib/acceptance-helpers.sh` (or has a documented reason
   not to).
3. It is read-only — no `curl -X POST`, no `nomad job run`, no `tea issues
   create`, no writes to the snapshot.
4. The assertions reference the actual artifact the change touched (not a
   stub or unrelated path).
5. `tools/run-acceptance.sh <N>` exits 0 on the live box.

If a test cannot run on the live box (operator interaction needed, etc.) the
PR is flagged `needs-deploy-verification` and not approved until a human or
supervisor confirms behavior by other means.

## How the process works post-merge

After a PR merges, its issue closes (the PR body says `Fixes #N`). The PR
already ran the issue's acceptance test in CI, unless the test is marked
`# acceptance-ci: skip`; such a test is run by hand on `disinto-nomad-box`
with `tools/run-acceptance.sh <N>`, and a failure is filed as a new issue.
