# 🏭 Dark Factory

Autonomous CI/CD factory for [harb](https://codeberg.org/johba/harb). Three agents, zero supervision needed.

## Architecture

```
cron (*/10) ──→ factory-poll.sh   ← supervisor (bash checks, zero tokens)
                 ├── all clear? → exit 0
                 └── problem? → claude -p (diagnose, fix, or escalate)

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

# 3. Install cron (staggered — supervisor first, then review, then dev)
crontab -e
# Add:
#   0,10,20,30,40,50 * * * * /path/to/dark-factory/factory/factory-poll.sh
#   3,13,23,33,43,53 * * * * /path/to/dark-factory/review/review-poll.sh
#   6,16,26,36,46,56 * * * * /path/to/dark-factory/dev/dev-poll.sh

# 4. Verify
bash factory/factory-poll.sh   # should log "all clear"
```

## Directory Structure

```
dark-factory/
├── .env.example        # Template — copy to .env, add secrets
├── .gitignore          # Excludes .env, logs, state files
├── lib/
│   ├── env.sh          # Shared: load .env, PATH, API helpers
│   └── ci-debug.sh     # Woodpecker CI log/failure helper
├── dev/
│   ├── dev-poll.sh     # Cron entry: find ready issues
│   └── dev-agent.sh    # Implementation agent (claude -p)
├── review/
│   ├── review-poll.sh  # Cron entry: find unreviewed PRs
│   └── review-pr.sh    # Review agent (claude -p)
└── factory/
    ├── factory-poll.sh # Supervisor: health checks + claude -p
    ├── PROMPT.md       # Supervisor's system prompt
    ├── update-prompt.sh# Self-learning: append to best-practices
    └── best-practices/ # Progressive disclosure knowledge base
        ├── memory.md
        ├── disk.md
        ├── ci.md
        ├── codeberg.md
        ├── dev-agent.md
        ├── review-agent.md
        └── git.md
```

## Design Principles

- **Bash for checks, AI for judgment** — health checks are shell scripts; AI is only invoked when something needs diagnosing or fixing
- **Pull over push** — dev-agent derives readiness from merged dependencies, not labels or manual assignment
- **Progressive disclosure** — the supervisor reads only the best-practices file relevant to the current problem, not all of them
- **Self-improving** — when the AI fixes something new, it appends the lesson to best-practices for next time

## Requirements

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) (`claude` in PATH)
- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`)
- [Woodpecker CI](https://woodpecker-ci.org/) (local instance)
- PostgreSQL client (`psql`)
- [OpenClaw](https://openclaw.ai/) (for escalation notifications, optional)
- `jq`, `curl`, `git`
