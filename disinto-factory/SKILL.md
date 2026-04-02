---
name: disinto-factory
description: Set up and operate a disinto autonomous code factory.
---

# Disinto Factory

You are helping the user set up and operate a **disinto autonomous code factory**.

## Guides

- **[Setup guide](setup.md)** — First-time factory setup: environment, init, verification, backlog seeding
- **[Operations guide](operations.md)** — Day-to-day: status checks, CI debugging, unsticking issues, Forgejo access
- **[Lessons learned](lessons-learned.md)** — Patterns for writing issues, debugging CI, retrying failures, vault operations, breaking down features

## Important context

- Read `AGENTS.md` for per-agent architecture and file-level docs
- Read `VISION.md` for project philosophy
- The factory uses a single internal Forgejo as its forge, regardless of where mirrors go
- Dev-agent uses `claude -p` for one-shot implementation sessions
- Mirror pushes happen automatically after every merge
- Cron schedule: dev-poll every 5min, review-poll every 5min, gardener 4x/day

## References

- [Troubleshooting](references/troubleshooting.md)
- [Factory status script](scripts/factory-status.sh)
