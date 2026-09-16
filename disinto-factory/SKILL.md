---
name: disinto-factory
description: Set up and operate a disinto autonomous code factory.
---

# Disinto Factory

You are helping the user set up and operate a **disinto autonomous code factory**.

## Guides

- **[Setup guide](setup.md)** — First-time factory setup: environment, init, verification, backlog seeding. Covers both backends; **Nomad+Vault (`bin/disinto init --backend=nomad`) is the recommended path**, docker-compose is legacy.
- **[Operations guide](operations.md)** — Day-to-day: status checks (`nomad job status`, `nomad alloc logs`, `bin/disinto role status`), CI debugging, unsticking issues, Forgejo access. Nomad commands first, legacy compose equivalents alongside.

## Important context

- The production factory (disinto-nomad-box) runs the **Nomad+Vault backend** (`bin/disinto init --backend=nomad`); the docker-compose stack is legacy. For migration/cutover details see `docs/nomad-migration.md`, for updating a running factory see `docs/updating-factory.md` (Nomad update path).
- Read `AGENTS.md` for per-agent architecture and file-level docs
- Read `VISION.md` for project philosophy
- The factory uses a single internal Forgejo as its forge, regardless of where mirrors go
- Dev-agent uses `claude -p` for one-shot implementation sessions
- Mirror pushes happen automatically after every merge
- Polling loop in `docker/agents/entrypoint.sh`: per-organ cadence scheduler (#1388) — dev-poll/review-poll every loop (every `POLL_INTERVAL`, default 5m), supervisor every 20 min, architect every 15 min, gardener every 6h, planner every 12h, predictor daily. `oak/tick.sh` runs alongside per project as a dry-run shadow (OAK_DRY_RUN=1, #1388): it senses, picks, and logs the organ it would start but never execs one (retires in #1390); `AGENT_ROLES` filters which organs the house runs

## References

- [Troubleshooting](references/troubleshooting.md)
- [Factory status script](scripts/factory-status.sh)
