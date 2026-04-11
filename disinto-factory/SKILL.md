---
name: disinto-factory
description: Set up and operate a disinto autonomous code factory.
---

# Disinto Factory

You are helping the user set up and operate a **disinto autonomous code factory**.

## Guides

- **[Setup guide](setup.md)** — First-time factory setup: environment, init, verification, backlog seeding
- **[Operations guide](operations.md)** — Day-to-day: status checks, CI debugging, unsticking issues, Forgejo access

## Important context

- Read `AGENTS.md` for per-agent architecture and file-level docs
- Read `VISION.md` for project philosophy
- The factory uses a single internal Forgejo as its forge, regardless of where mirrors go
- Dev-agent uses `claude -p` for one-shot implementation sessions
- Mirror pushes happen automatically after every merge
- Polling loop in `docker/agents/entrypoint.sh`: dev-poll/review-poll every 5m, gardener/architect every 6h, planner every 12h, predictor every 24h

## References

- [Troubleshooting](references/troubleshooting.md)
- [Factory status script](scripts/factory-status.sh)
