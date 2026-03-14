# Dark Factory

Autonomous CI/CD factory. Four agents, zero supervision needed.

Point it at a Codeberg repo with a Woodpecker CI pipeline and it will pick up issues, implement them, review PRs, and keep the system healthy — all on its own.

## Architecture

```
cron (*/10) ──→ factory-poll.sh    ← supervisor (bash checks, zero tokens)
                 ├── all clear? → exit 0
                 └── problem? → claude -p (diagnose, fix, or escalate)

cron (*/10) ──→ dev-poll.sh        ← pulls ready issues, spawns dev-agent
                 └── dev-agent.sh   ← claude -p: implement → PR → CI → review → merge

cron (*/10) ──→ review-poll.sh     ← finds unreviewed PRs, spawns review
                 └── review-pr.sh   ← claude -p: review → approve/request changes

cron (daily) ──→ gardener-poll.sh  ← backlog grooming (duplicates, stale, tech-debt)
                  └── claude -p: triage → promote/close/escalate
```

## Prerequisites

**Required:**

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) — `claude` in PATH, authenticated
- [Codeberg](https://codeberg.org/) account with an API token — the factory reads issues, opens PRs, posts comments, and merges via the Codeberg API
- A second Codeberg account for the review bot — reviews posted under a separate identity so the dev-agent doesn't review its own PRs (`REVIEW_BOT_TOKEN`)
- [Woodpecker CI](https://woodpecker-ci.org/) — local instance connected to your Codeberg repo; the factory monitors pipelines, retries failures, and queries the Woodpecker Postgres DB directly
- PostgreSQL client (`psql`) — for Woodpecker DB queries (pipeline status, build counts)
- `jq`, `curl`, `git`

**Optional:**

- [OpenClaw](https://openclaw.ai/) — escalation notifications; when agents hit something they can't resolve, they send a system event via `openclaw` CLI
- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`) — only needed if your target project uses Solidity
- [Node.js](https://nodejs.org/) — only needed if your target project uses Node

## Setup

```bash
# 1. Clone
git clone ssh://git@codeberg.org/johba/dark-factory.git
cd dark-factory

# 2. Configure
cp .env.example .env
```

Edit `.env` with your values:

```bash
# Target repo
CODEBERG_REPO=yourorg/yourproject              # Codeberg org/repo slug
CODEBERG_API=https://codeberg.org/api/v1/repos/yourorg/yourproject
PROJECT_REPO_ROOT=/path/to/your/project        # local clone of the target repo

# Auth tokens
CODEBERG_TOKEN=...          # main account — or put it in ~/.netrc
REVIEW_BOT_TOKEN=...        # separate Codeberg account for code reviews

# Woodpecker CI
WOODPECKER_SERVER=http://localhost:8000
WOODPECKER_TOKEN=...
WOODPECKER_DB_PASSWORD=...
WOODPECKER_DB_USER=woodpecker
WOODPECKER_DB_HOST=127.0.0.1
WOODPECKER_DB_NAME=woodpecker

# Tuning
CLAUDE_TIMEOUT=7200         # max seconds per Claude invocation (default: 2h)
```

```bash
# 3. Install cron (staggered to avoid overlap)
crontab -e
# Add:
#   0,10,20,30,40,50 * * * * /path/to/dark-factory/factory/factory-poll.sh
#   3,13,23,33,43,53 * * * * /path/to/dark-factory/review/review-poll.sh
#   6,16,26,36,46,56 * * * * /path/to/dark-factory/dev/dev-poll.sh
#   15 8 * * *                /path/to/dark-factory/gardener/gardener-poll.sh

# 4. Verify
bash factory/factory-poll.sh   # should log "all clear"
```

## Directory Structure

```
dark-factory/
├── .env.example          # Template — copy to .env, add secrets + project config
├── .gitignore            # Excludes .env, logs, state files
├── lib/
│   ├── env.sh            # Shared: load .env, PATH, Codeberg/Woodpecker API helpers
│   └── ci-debug.sh       # Woodpecker CI log/failure helper
├── dev/
│   ├── dev-poll.sh       # Cron entry: find ready issues
│   └── dev-agent.sh      # Implementation agent (claude -p)
├── review/
│   ├── review-poll.sh    # Cron entry: find unreviewed PRs
│   └── review-pr.sh      # Review agent (claude -p)
├── gardener/
│   ├── gardener-poll.sh  # Cron entry: backlog grooming
│   └── best-practices.md # Gardener knowledge base
└── factory/
    ├── factory-poll.sh   # Supervisor: health checks + claude -p
    ├── PROMPT.md         # Supervisor's system prompt
    ├── update-prompt.sh  # Self-learning: append to best-practices
    └── best-practices/   # Progressive disclosure knowledge base
        ├── memory.md
        ├── disk.md
        ├── ci.md
        ├── codeberg.md
        ├── dev-agent.md
        ├── review-agent.md
        └── git.md
```

## Agents

| Agent | Trigger | Job |
|-------|---------|-----|
| **Factory** (supervisor) | Every 10 min | Health checks (RAM, disk, CI, git). Calls Claude only when something is broken. Self-improving via `best-practices/`. |
| **Dev** | Every 10 min | Picks up `backlog`-labeled issues, creates a branch, implements, opens a PR, monitors CI, responds to review, merges. |
| **Review** | Every 10 min | Finds PRs without review, runs Claude-powered code review, approves or requests changes. |
| **Gardener** | Daily | Grooms the issue backlog: detects duplicates, promotes `tech-debt` to `backlog`, closes stale issues, escalates ambiguous items. |

## Design Principles

- **Bash for checks, AI for judgment** — polling and health checks are shell scripts; Claude is only invoked when something needs diagnosing or deciding
- **Pull over push** — dev-agent derives readiness from merged dependencies, not labels or manual assignment
- **Progressive disclosure** — the supervisor reads only the best-practices file relevant to the current problem, not all of them
- **Self-improving** — when Claude fixes something new, the lesson is appended to best-practices for next time
- **Project-agnostic** — all project-specific values (repo, paths, CI IDs) come from `.env`, not hardcoded scripts

