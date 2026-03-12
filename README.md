# 🏭 Dark Factory

Autonomous CI/CD factory for [harb](https://codeberg.org/johba/harb). Three agents, zero supervision needed.

## Architecture

```
cron (*/10) ──→ factory-poll.sh   ← supervisor (bash checks, zero tokens)
                 ├── all clear? → exit 0
                 └── problem? → alert (or claude -p for complex fixes)

cron (*/10) ──→ dev-poll.sh       ← pulls ready issues, spawns dev-agent
                 └── dev-agent.sh  ← claude -p: implement → PR → CI → review → merge

cron (*/10) ──→ review-poll.sh    ← finds unreviewed PRs, spawns review
                 └── review-pr.sh  ← claude -p: review → approve/request changes
```

## Setup

```bash
# 1. Clone
git clone ssh://git@codeberg.org/johba/dark-factory.git
cd dark-factory

# 2. Configure
cp .env.example .env
# Fill in your tokens (see .env.example for descriptions)

# 3. Install cron
crontab -e
# Add:
#   */10 * * * * /path/to/dark-factory/factory/factory-poll.sh
#   */10 * * * * /path/to/dark-factory/dev/dev-poll.sh
#   */10 * * * * /path/to/dark-factory/review/review-poll.sh

# 4. Verify
bash factory/factory-poll.sh   # should log "all clear"
```

## Directory Structure

```
dark-factory/
├── .env.example        # Template — copy to .env, add secrets
├── .gitignore          # Excludes .env, logs, state files
├── lib/
│   └── env.sh          # Shared: load .env, PATH, API helpers
├── dev/
│   ├── dev-poll.sh     # Cron entry: find ready issues
│   ├── dev-agent.sh    # Implementation agent (claude -p)
│   └── ci-debug.sh     # Woodpecker CI log helper
├── review/
│   ├── review-poll.sh  # Cron entry: find unreviewed PRs
│   └── review-pr.sh    # Review agent (claude -p)
└── factory/
    └── factory-poll.sh # Supervisor: health checks + auto-fix
```

## How It Works

### Dev Agent (Pull System)
1. `dev-poll.sh` scans `backlog`-labeled issues
2. Checks if all dependencies are merged into master
3. Picks the first ready issue, spawns `dev-agent.sh`
4. Agent: creates worktree → `claude -p` implements → commits → pushes → creates PR
5. Waits for CI. If CI fails: feeds errors back to claude (max 2 attempts per phase)
6. Waits for review. If REQUEST_CHANGES: feeds review back to claude
7. On APPROVE: merges PR, cleans up, closes issue

### Review Agent
1. `review-poll.sh` finds open PRs with passing CI and no review
2. Spawns `review-pr.sh` which runs `claude -p` to review the diff
3. Posts structured review comment with verdict (APPROVE / REQUEST_CHANGES / DISCUSS)
4. Creates follow-up issues for pre-existing bugs found during review

### Factory Supervisor
1. `factory-poll.sh` runs pure bash checks every 10 minutes:
   - CI: stuck or failing pipelines
   - PRs: derailed (CI fail + no activity)
   - Dev-agent: alive and making progress
   - Git: clean state on master
   - Infra: RAM, swap, disk, Anvil health
   - Review: unreviewed PRs with passing CI
2. Auto-fixes simple issues (restart Anvil, retrigger CI)
3. Escalates complex issues via openclaw system event

## Requirements

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (`claude` in PATH)
- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)
- [Woodpecker CI](https://woodpecker-ci.org/) (local instance)
- PostgreSQL client (`psql`)
- [OpenClaw](https://openclaw.ai/) (for system event notifications, optional)
- `jq`, `curl`, `git`

## Design Principles

- **Bash for checks, AI for fixes** — don't burn tokens on health checks
- **Pull system** — readiness derived from merged dependencies, not labels
- **CI fix loop** — each phase gets fresh retry budget
- **Prior art** — dev-agent searches closed PRs to avoid rework
- **No secrets in repo** — everything via `.env`
