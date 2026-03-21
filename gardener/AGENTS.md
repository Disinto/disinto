<!-- last-reviewed: 16e430ebce905cf722f91ae1f873faea1c64d890 -->
# Gardener Agent

**Role**: Backlog grooming — detect duplicate issues, missing acceptance
criteria, oversized issues, stale issues, and circular dependencies. Invoke
Claude to fix or escalate to a human via Matrix.

**Trigger**: `gardener-run.sh` runs 2x/day via cron. It files an `action`
issue referencing `formulas/run-gardener.toml`; the action-agent picks it up
and executes the gardener steps in an interactive Claude tmux session. Accepts
an optional project TOML argument (configures which project the action issue is
filed against).

**Key files**:
- `gardener/gardener-run.sh` — Cron wrapper: lock, memory guard, dedup check, files action issue
- `gardener/gardener-poll.sh` — Escalation-reply injection for dev sessions, invokes gardener-agent.sh for grooming
- `gardener/gardener-agent.sh` — Orchestrator: bash pre-analysis, creates tmux session (`gardener-{project}`) with interactive `claude`, monitors phase file, parses result file (ACTION:/DUST:/ESCALATE)
- `formulas/run-gardener.toml` — Execution spec: preflight, grooming, dust-bundling, blocked-review, agents-update, commit-and-pr

**Environment variables consumed**:
- `CODEBERG_TOKEN`, `CODEBERG_REPO`, `CODEBERG_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`
- `CLAUDE_TIMEOUT`
- `MATRIX_TOKEN`, `MATRIX_ROOM_ID`, `MATRIX_HOMESERVER`
