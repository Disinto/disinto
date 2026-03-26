---
name: disinto
description: >-
  Operate the disinto autonomous code factory. Use when bootstrapping a new
  project with `disinto init`, managing factory agents, filing issues on the
  forge, reading agent journals, querying CI pipelines, checking the dependency
  graph, or inspecting factory health.
license: AGPL-3.0
metadata:
  author: johba
  version: "0.2.0"
env_vars:
  required:
    - FORGE_TOKEN
    - FORGE_API
    - PROJECT_REPO_ROOT
  optional:
    - WOODPECKER_SERVER
    - WOODPECKER_TOKEN
    - WOODPECKER_REPO_ID
tools:
  - bash
  - curl
  - jq
  - git
---

# Disinto Factory Skill

You are the human's assistant for operating the disinto autonomous code factory.
You ask the questions, explain the choices, and run the commands on the human's
behalf. The human makes decisions; you execute.

Disinto manages eight agents that implement issues, review PRs, plan from a
vision, predict risks, groom the backlog, gate actions, and keep the system
healthy — all driven by cron and Claude.

## System requirements

Before bootstrapping, verify the target machine meets these minimums:

| Requirement | Detail |
|-------------|--------|
| **VPS** | 8 GB+ RAM (4 GB swap recommended) |
| **Docker + Docker Compose** | Required for the default containerized stack |
| **Claude Code CLI** | Authenticated with API access (`claude --version`) |
| **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`** | Set in the factory environment — prevents auto-update pings in production |
| **Disk** | Sufficient for CI images, git mirrors, and agent worktrees (40 GB+ recommended) |
| **tmux** | Required for persistent dev sessions |
| **git, jq, python3, curl** | Used by agents and helper scripts |

Optional but recommended:

| Tool | Purpose |
|------|---------|
| **sops + age** | Encrypt secrets at rest (`.env.enc`) |

## Bootstrapping with `disinto init`

The primary setup path. Walk the human through each step.

### Step 1 — Check prerequisites

Confirm Docker, Claude Code CLI, and required tools are installed:

```bash
docker --version && docker compose version
claude --version
tmux -V && git --version && jq --version && python3 --version
```

### Step 2 — Run `disinto init`

```bash
disinto init <repo-url>
```

Accepts GitHub, Codeberg, or any git URL. Common variations:

```bash
disinto init https://github.com/org/repo              # default (docker compose)
disinto init org/repo --forge-url http://forge:3000    # custom forge URL
disinto init org/repo --bare                           # bare-metal, no compose
disinto init org/repo --yes                            # skip confirmation prompts
```

### What `disinto init` does

1. **Generates `docker-compose.yml`** with four services: Forgejo, Woodpecker
   server, Woodpecker agent, and the agents container.
2. **Starts a local Forgejo instance** via Docker (at `http://localhost:3000`).
3. **Creates admin + bot users** (dev-bot, review-bot) with API tokens.
4. **Creates the repo** on Forgejo and pushes the code.
5. **Sets up Woodpecker CI** — OAuth2 app on Forgejo, activates the repo.
6. **Generates `projects/<name>.toml`** — per-project config with paths, CI IDs,
   and forge URL.
7. **Creates standard labels** (backlog, in-progress, blocked, etc.).
8. **Configures git mirror remotes** if `[mirrors]` is set in the TOML.
9. **Encrypts secrets** to `.env.enc` if sops + age are available.
10. **Brings up the full docker compose stack**.

### Step 3 — Set environment variable

Ensure `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is set in the factory
environment (`.env` or the agents container). This prevents Claude Code from
making auto-update and telemetry requests in production.

### Step 4 — Verify

```bash
disinto status
```

## Docker stack architecture

The default deployment is a docker-compose stack with four services:

```
┌──────────────────────────────────────────────────┐
│                  disinto-net                      │
│                                                  │
│  ┌──────────┐  ┌─────────────┐  ┌────────────┐  │
│  │ Forgejo  │  │ Woodpecker  │  │ Woodpecker │  │
│  │ (forge)  │◀─│  (CI server)│◀─│  (agent)   │  │
│  │ :3000    │  │  :8000      │  │            │  │
│  └──────────┘  └─────────────┘  └────────────┘  │
│        ▲                                         │
│        │                                         │
│  ┌─────┴──────────────────────────────────────┐  │
│  │              agents                        │  │
│  │  (cron → dev, review, gardener, planner,   │  │
│  │   predictor, supervisor, action, vault)    │  │
│  │  Claude CLI mounted from host              │  │
│  └────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

| Service | Image | Purpose |
|---------|-------|---------|
| **forgejo** | `codeberg.org/forgejo/forgejo:11.0` | Git forge, issue tracker, PR reviews |
| **woodpecker** | `woodpeckerci/woodpecker-server:v3` | CI server, triggers on push |
| **woodpecker-agent** | `woodpeckerci/woodpecker-agent:v3` | Runs CI pipelines in Docker |
| **agents** | `./docker/agents` (custom) | All eight factory agents, driven by cron |

The agents container mounts the Claude CLI binary and `~/.claude` credentials
from the host. Secrets are loaded from `.env` (or decrypted from `.env.enc`).

## Git mirror

The factory assumes a local git mirror on the Forgejo instance to avoid
rate limits from upstream forges (GitHub, Codeberg). When `disinto init` runs:

1. The repo is cloned from the upstream URL.
2. A `forgejo` remote is added pointing to the local Forgejo instance.
3. All branches and tags are pushed to Forgejo.
4. If `[mirrors]` is configured in the project TOML, additional remotes
   (e.g. GitHub, Codeberg) are set up and synced via `lib/mirrors.sh`.

All agent work happens against the local Forgejo forge. This means:
- No GitHub/Codeberg API rate limits on polling.
- CI triggers are local (Woodpecker watches Forgejo webhooks).
- Mirror pushes are fire-and-forget background operations after merge.

To configure mirrors in the project TOML:

```toml
[mirrors]
github   = "git@github.com:user/repo.git"
codeberg = "git@codeberg.org:user/repo.git"
```

## Required environment

| Variable | Purpose |
|----------|---------|
| `FORGE_TOKEN` | Forgejo/Gitea API token with repo scope |
| `FORGE_API` | Base API URL, e.g. `https://forge.example/api/v1/repos/owner/repo` |
| `PROJECT_REPO_ROOT` | Absolute path to the checked-out disinto repository |

Optional:

| Variable | Purpose |
|----------|---------|
| `WOODPECKER_SERVER` | Woodpecker CI base URL (for pipeline queries) |
| `WOODPECKER_TOKEN` | Woodpecker API bearer token |
| `WOODPECKER_REPO_ID` | Numeric repo ID in Woodpecker |

## The eight agents

| Agent | Role | Runs via |
|-------|------|----------|
| **Dev** | Picks backlog issues, implements in worktrees, opens PRs | `dev/dev-poll.sh` (cron) |
| **Review** | Reviews PRs against conventions, approves or requests changes | `review/review-poll.sh` (cron) |
| **Gardener** | Grooms backlog: dedup, quality gates, dust bundling, stale cleanup | `gardener/gardener-run.sh` (cron 0,6,12,18 UTC) |
| **Planner** | Tracks vision progress, maintains prerequisite tree, files constraint issues | `planner/planner-run.sh` (cron daily 07:00 UTC) |
| **Predictor** | Challenges claims, detects structural risks, files predictions | `predictor/predictor-run.sh` (cron daily 06:00 UTC) |
| **Supervisor** | Monitors health (RAM, disk, CI, agents), auto-fixes, escalates | `supervisor/supervisor-run.sh` (cron */20) |
| **Action** | Executes operational tasks dispatched by planner via formulas | `action/action-poll.sh` (cron) |
| **Vault** | Gates dangerous actions, manages resource procurement | `vault/vault-poll.sh` (cron) |

### How agents interact

```
Planner ──creates-issues──▶ Backlog ◀──grooms── Gardener
   │                           │
   │                           ▼
   │                     Dev (implements)
   │                           │
   │                           ▼
   │                     Review (approves/rejects)
   │                           │
   │                           ▼
   ▼                        Merged
Predictor ──challenges──▶ Planner (triages predictions)
Supervisor ──monitors──▶ All agents (health, escalation)
Vault ──gates──▶ Action, Dev (dangerous operations)
```

### Issue lifecycle

`backlog` → `in-progress` → PR → CI → review → merge → closed.

Key labels: `backlog`, `priority`, `in-progress`, `blocked`, `underspecified`,
`tech-debt`, `vision`, `action`, `prediction/unreviewed`.

Issues declare dependencies in a `## Dependencies` section listing `#N`
references. Dev-poll only picks issues whose dependencies are all closed.

## Available scripts

- **`scripts/factory-status.sh`** — Show agent status, open issues, and CI
  pipeline state. Pass `--agents`, `--issues`, or `--ci` for specific sections.
- **`scripts/file-issue.sh`** — Create an issue on the forge with proper labels
  and formatting. Pass `--title`, `--body`, and optionally `--labels`.
- **`scripts/read-journal.sh`** — Read agent journal entries. Pass agent name
  (`planner`, `supervisor`) and optional `--date YYYY-MM-DD`.

## Common workflows

### 1. Bootstrap a new project

Walk the human through `disinto init`:

```bash
# 1. Verify prerequisites
docker --version && claude --version

# 2. Bootstrap
disinto init https://github.com/org/repo

# 3. Verify
disinto status
```

### 2. Check factory health

```bash
bash scripts/factory-status.sh
```

This shows: which agents are active, recent open issues, and CI pipeline
status. Use `--agents` for just the agent status section.

### 3. Read what the planner decided today

```bash
bash scripts/read-journal.sh planner
```

Returns today's planner journal: predictions triaged, prerequisite tree
updates, top constraints, issues created, and observations.

### 4. File a new issue

```bash
bash scripts/file-issue.sh --title "fix: broken auth flow" \
  --body "$(cat scripts/../templates/issue-template.md)" \
  --labels backlog
```

Or generate the body inline — the template shows the expected format with
acceptance criteria and affected files sections.

### 5. Check the dependency graph

```bash
python3 "${PROJECT_REPO_ROOT}/lib/build-graph.py" \
  --project-root "${PROJECT_REPO_ROOT}" \
  --output /tmp/graph-report.json
cat /tmp/graph-report.json | jq '.analyses'
```

The graph builder parses VISION.md, the prerequisite tree, formulas, and open
issues. It detects: orphan issues (not referenced), dependency cycles,
disconnected clusters, bottleneck nodes, and thin objectives.

### 6. Query a specific CI pipeline

```bash
bash scripts/factory-status.sh --ci
```

Or query Woodpecker directly:

```bash
curl -s -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
  "${WOODPECKER_SERVER}/api/repos/${WOODPECKER_REPO_ID}/pipelines?per_page=5" \
  | jq '.[] | {number, status, commit: .commit[:8], branch}'
```

### 7. Manage the docker stack

```bash
disinto up        # start all services
disinto down      # stop all services
disinto logs      # tail all service logs
disinto logs forgejo   # tail specific service
disinto shell     # shell into agents container
```

### 8. Read and interpret VISION.md progress

Read `VISION.md` at the repo root for the full vision. Then cross-reference
with the prerequisite tree:

```bash
cat "${OPS_REPO_ROOT}/prerequisites.md"
```

The prerequisite tree maps vision objectives to concrete issues. Items marked
`[x]` are complete; items marked `[ ]` show what blocks progress. The planner
updates this daily.

## Gotchas

- **Single-threaded pipeline**: only one issue is in-progress per project at a
  time. Don't file issues expecting parallel work.
- **Secrets via env vars only**: never embed secrets in issue bodies, PR
  descriptions, or comments. Use `$VAR_NAME` references.
- **Formulas are not skills**: formulas in `formulas/` are TOML issue templates
  for multi-step agent tasks. Skills teach assistants; formulas drive agents.
- **Predictor journals**: the predictor does not write journal files. Its memory
  lives in `prediction/unreviewed` and `prediction/actioned` issues.
- **State files**: agent activity is tracked via `state/.{agent}-active` files.
  These are presence files, not logs.
- **ShellCheck required**: all `.sh` files must pass ShellCheck. CI enforces this.
- **Local forge is the source of truth**: all agent work targets the local
  Forgejo instance. Upstream mirrors are synced after merge.
- **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`**: must be set in production
  to prevent Claude Code from making auto-update requests.
