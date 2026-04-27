# Acceptance tests

This directory holds the runnable acceptance test for every backlog issue that
ships behavior. Issues reference a file path in here; the file is the source of
truth.

## Naming

`tests/acceptance/issue-<N>.sh` — one file per issue number, e.g.
`tests/acceptance/issue-844.sh`. The runner discovers tests by this exact path.

## Contract

Every acceptance test:

1. **Is bash, executable** — `#!/usr/bin/env bash` with `chmod +x`.
2. **Sets strict mode** — `set -euo pipefail`.
3. **Exits 0 on pass, non-zero on fail.**
4. **Prints `PASS` as its last stdout line on success, or `FAIL: <reason>` on
   failure.** stderr is for diagnostics; stdout drives the outcome.
5. **Is read-only.** Tests query forge, nomad, the snapshot, and chat/voice
   endpoints — they do not file issues, dispatch jobs, or otherwise mutate
   state. This is enforced by convention: reviewer-agent rejects mutating
   tests. (There is no sandbox.)
6. **Sources helpers** from `tests/lib/acceptance-helpers.sh` for curl
   wrappers, jq assertions, and logging — instead of hand-rolling the same
   plumbing per file.

## Running

The canonical entry point is the runner in `tools/`:

```bash
tools/run-acceptance.sh 844                 # human-readable
tools/run-acceptance.sh --format json 844   # machine-readable
```

The runner sources the daemon's env (`FORGE_URL`, `NOMAD_ADDR`,
`FACTORY_FORGE_PAT`, etc.) from `/etc/disinto/acceptance.env` or — if that
file isn't present — pulls them live from the running snapshot daemon's
`/proc/<pid>/environ`. Override with `RUN_ACCEPTANCE_ENV_FILE=/path/to/env`.

The runner's exit code mirrors the test's exit code, so it composes cleanly
with CI, watchdogs, and `&&` chains.

## Skeleton

```bash
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/acceptance-helpers.sh"

ac_require_cmd curl jq
ac_require_env FORGE_URL FACTORY_FORGE_PAT

ac_log "checking issue 844 is closed"
issue="$(ac_forge_api "repos/disinto-admin/disinto/issues/844")"
ac_assert_jq '.state == "closed"' "$issue" "issue 844 is not closed"

echo PASS
```

## Why files, not inline commands

Earlier issues stuffed acceptance commands inline in the issue body. That
worked as a forcing function but didn't survive contact with reuse: commands
in markdown rot, can't be linted, can't be sourced from CI, and require a
human in the loop to execute. Files in the repo are version-controlled,
shellcheck-able, callable from CI, and survive the issue being closed.

Inline commands stay as a fallback for cases where a CI test is genuinely
infeasible (e.g. tests that require operator interaction). The default is the
file convention.

## See also

- `docs/contributing/acceptance-tests.md` — full convention and rationale.
- `tools/run-acceptance.sh` — the runner.
- `tests/lib/acceptance-helpers.sh` — shared helpers.
