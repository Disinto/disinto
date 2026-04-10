<div align="center">
  <img src="site/al76.jpg" alt="A tiny robot commanding a mountain-eating machine" width="600">
  <br><br>

  # Disinto

  **Autonomous code factory** — [disinto.ai](https://disinto.ai)

  [![ClawHub](https://clawhub.ai/badge/disinto)](https://clawhub.ai/skills/disinto)

  *A mining robot, lost and confused, builds a Disinto from scrap —<br>
  a device so powerful it vaporizes three-quarters of a mountain on a single battery.*<br>
  — Isaac Asimov, "Robot AL-76 Goes Astray" (1942)

</div>

<br>

Point it at a git repo with a Woodpecker CI pipeline and it will pick up issues, implement them, review PRs, and keep the system healthy — all on its own.

## Architecture

```
entrypoint.sh (while-true polling loop, 5 min base interval)
 │
 ├── every 5 min ──→ review-poll.sh   ← finds unreviewed PRs, spawns review
 │                    └── review-pr.sh  ← claude -p: review → approve/request changes
 │
 ├── every 5 min ──→ dev-poll.sh      ← pulls ready issues, spawns dev-agent
 │                    └── dev-agent.sh  ← claude -p: implement → PR → CI → review → merge
 │
 ├── every 6h ────→ gardener-run.sh   ← backlog grooming (duplicates, stale, tech-debt)
 │                   └── claude -p: triage → promote/close/escalate
 │
 ├── every 6h ────→ architect-run.sh  ← strategic decomposition of vision into sprints
 │
 ├── every 12h ───→ planner-run.sh    ← gap-analyse VISION.md, create backlog issues
 │                   └── claude -p: update AGENTS.md → create issues
 │
 └── every 24h ───→ predictor-run.sh  ← infrastructure pattern detection

entrypoint-edge.sh (edge container)
 ├── dispatcher.sh                    ← polls ops repo for vault actions
 └── every 20 min → supervisor-run.sh ← health checks (bash checks, zero tokens)
                     ├── all clear? → exit 0
                     └── problem? → claude -p (diagnose, fix, or escalate)
```

## Prerequisites

**Required:**

- [Claude CLI](https://docs.anthropic.com/en/docs/claude-cli) — `claude` in PATH, authenticated
- [Docker](https://docker.com/) — for provisioning a local Forgejo instance (or a running Forgejo/Gitea instance)
- [Woodpecker CI](https://woodpecker-ci.org/) — local instance connected to your forge; disinto monitors pipelines, retries failures, and queries the Woodpecker Postgres DB directly
- PostgreSQL client (`psql`) — for Woodpecker DB queries (pipeline status, build counts)
- `jq`, `curl`, `git`

**Optional:**

- [Foundry](https://getfoundry.sh/) (`forge`, `cast`, `anvil`) — only needed if your target project uses Solidity
- [Node.js](https://nodejs.org/) — only needed if your target project uses Node

## Setup

```bash
# 1. Clone
git clone https://github.com/johba/disinto.git
cd disinto

# 2. Bootstrap a project (provisions local Forgejo, creates tokens, clones repo)
disinto init https://github.com/yourorg/yourproject
```

Or configure manually — edit `.env` with your values:

```bash
# Forge (auto-populated by disinto init)
FORGE_URL=http://localhost:3000        # local Forgejo instance
FORGE_TOKEN=...             # dev-bot token
FORGE_REVIEW_TOKEN=...      # review-bot token

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
# 3. Start the agent and edge containers
docker compose up -d

# 4. Verify the entrypoint loop is running
docker exec disinto-agents-1 tail -f /home/agent/data/agent-entrypoint.log
```

## Directory Structure

```
disinto/
├── .env.example          # Template — copy to .env, add secrets + project config
├── .gitignore            # Excludes .env, logs, state files
├── lib/
│   ├── env.sh              # Shared: load .env, PATH, API helpers
│   └── ci-debug.sh         # Woodpecker CI log/failure helper
├── dev/
│   ├── dev-poll.sh       # Poll: find ready issues
│   └── dev-agent.sh      # Implementation agent (claude -p)
├── review/
│   ├── review-poll.sh    # Poll: find unreviewed PRs
│   └── review-pr.sh      # Review agent (claude -p)
├── gardener/
│   ├── gardener-run.sh   # Executor: backlog grooming
│   └── best-practices.md # Gardener knowledge base
├── planner/
│   ├── planner-run.sh    # Executor: vision gap analysis
│   └── (formula-driven)  # run-planner.toml executed by dispatcher
├── vault/
│   └── vault-env.sh      # Shared env setup (vault redesign in progress, see #73-#77)
├── docs/
│   └── VAULT.md          # Vault PR workflow and branch protection documentation
└── supervisor/
    ├── supervisor-poll.sh   # Supervisor: health checks + claude -p
    ├── update-prompt.sh  # Self-learning: append to best-practices
    └── best-practices/   # Progressive disclosure knowledge base
        ├── memory.md
        ├── disk.md
        ├── ci.md
        ├── forge.md
        ├── dev-agent.md
        ├── review-agent.md
        └── git.md
```

## Agents

| Agent | Trigger | Job |
|-------|---------|-----|
| **Supervisor** | Every 20 min | Health checks (RAM, disk, CI, git). Calls Claude only when something is broken. Self-improving via `best-practices/`. |
| **Dev** | Every 5 min | Picks up `backlog`-labeled issues, creates a branch, implements, opens a PR, monitors CI, responds to review, merges. |
| **Review** | Every 5 min | Finds PRs without review, runs Claude-powered code review, approves or requests changes. |
| **Gardener** | Every 6h | Grooms the issue backlog: detects duplicates, promotes `tech-debt` to `backlog`, closes stale issues, escalates ambiguous items. |
| **Planner** | Every 12h | Updates AGENTS.md documentation to reflect recent code changes, then gap-analyses VISION.md vs current state and creates up to 5 backlog issues for the highest-leverage gaps. |

> **Vault:** Being redesigned as a PR-based approval workflow (issues #73-#77).
> See [docs/VAULT.md](docs/VAULT.md) for the vault PR workflow and branch protection details.

## Design Principles

- **Bash for checks, AI for judgment** — polling and health checks are shell scripts; Claude is only invoked when something needs diagnosing or deciding
- **Pull over push** — dev-agent derives readiness from merged dependencies, not labels or manual assignment
- **Progressive disclosure** — the supervisor reads only the best-practices file relevant to the current problem, not all of them
- **Self-improving** — when Claude fixes something new, the lesson is appended to best-practices for next time
- **Project-agnostic** — all project-specific values (repo, paths, CI IDs) come from `.env`, not hardcoded scripts

### Runtime constraints

Disinto is intentionally opinionated about its own runtime. These are hard constraints, not preferences:

- **Debian + GNU userland** — all scripts target Debian with standard GNU tools (`bash`, `awk`, `sed`, `date`, `timeout`). No portability shims for macOS or BSD.
- **Shell + a small set of runtimes** — every agent is a bash script. The only interpreted runtimes used by disinto core are `python3` (TOML parsing in `lib/load-project.sh`, JSON state tracking in `dev/dev-poll.sh`, recipe matching in `gardener/gardener-poll.sh`) and `claude` (the AI CLI). No Ruby, Perl, or other runtimes. Do not add new runtime dependencies without a strong justification.
- **Few, powerful dependencies** — required non-standard tools: `jq`, `curl`, `git`, `tmux`, `psql`, and `python3` (≥ 3.11 for `tomllib`; or install `tomli` for older Pythons). Adding anything beyond this list requires justification.
- **Node.js and Foundry are target-project dependencies** — if your target repo uses Node or Solidity, install those on the host. They are not part of disinto's core and must not be assumed present in disinto scripts.

The goal: any Debian machine with the prerequisites listed above can run disinto. Keep it that way.

