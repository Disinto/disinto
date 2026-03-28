# CLAUDE.md

This repo is **disinto** — an autonomous code factory.

For setup and operations, load the `disinto-factory` skill from `disinto-factory/SKILL.md`.

Quick references:
- `AGENTS.md` — per-agent architecture and file-level docs
- `VISION.md` — project philosophy
- `BOOTSTRAP.md` — detailed init walkthrough
- `disinto-factory/references/troubleshooting.md` — common issues and fixes
- `disinto-factory/scripts/factory-status.sh` — quick status check

## Code conventions

- Bash for checks, AI for judgment
- Zero LLM tokens when idle (cron polls are pure bash)
- Fire-and-forget mirror pushes (never block the pipeline)
- Issues are the unit of work; PRs are the delivery mechanism
- See `AGENTS.md` for per-file watermarks and coding conventions
