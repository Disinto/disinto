<!-- last-reviewed: f10cdf2c9e44c32308c7ea74fcc3139407703e59 -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages seven agents (dev, review,
gardener, supervisor, planner, predictor, architect) that pick up issues from
forge, implement them, review PRs, plan from the vision, and keep the system
healthy — all via cron and `claude -p`. The dispatcher executes formula-based
operational tasks.

Each agent has a `.profile` repository on Forgejo that stores lessons learned
from prior sessions, providing continuous improvement across runs.

> **Note:** The vault is being redesigned as a PR-based approval workflow on the
> ops repo (see issues #73-#77). See [docs/VAULT.md](docs/VAULT.md) for details. Old vault scripts are being removed.

See `README.md` for the full architecture and `disinto-factory/SKILL.md` for setup.

## Directory layout

```
disinto/                 (code repo)
├── dev/           dev-poll.sh, dev-agent.sh, phase-test.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-run.sh — direct cron executor for run-gardener formula
├── predictor/     predictor-run.sh — daily cron executor for run-predictor formula
├── planner/       planner-run.sh — direct cron executor for run-planner formula
├── supervisor/    supervisor-run.sh — formula-driven health monitoring (cron wrapper)
│                  preflight.sh — pre-flight data collection for supervisor formula
│                  supervisor-poll.sh — legacy bash orchestrator (superseded)
├── architect/     architect-run.sh — strategic decomposition of vision into sprints
├── vault/         vault-env.sh — shared env setup (vault redesign in progress, see #73-#77)
├── lib/           env.sh, agent-sdk.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, guard.sh, mirrors.sh, pr-lifecycle.sh, issue-lifecycle.sh, worktree.sh, formula-session.sh, stack-lock.sh, build-graph.py
├── projects/      *.toml.example — templates; *.toml — local per-box config (gitignored)
├── formulas/      Issue templates (TOML specs for multi-step agent tasks)
└── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md)

disinto-ops/             (ops repo — {project}-ops)
├── vault/
│   ├── pending/   vault items awaiting approval
│   ├── approved/  approved vault items
│   ├── fired/     executed vault items
│   └── rejected/  rejected vault items
├── knowledge/     shared agent knowledge + best practices
├── evidence/      engagement data, experiment results
├── portfolio.md   addressables + observables
├── prerequisites.md  dependency graph
└── RESOURCES.md   accounts, tokens (refs), infra inventory
```

> **Note:** Journal directories (`journal/planner/` and `journal/supervisor/`) have been removed from the ops repo. Agent journals are now stored in each agent's `.profile` repo on Forgejo.

## Agent .profile Model

Each agent has a `.profile` repository on Forgejo storing `knowledge/lessons-learned.md` (injected into each session prompt) and `journal/` reflection entries (digested into lessons). Pre-session: `formula_prepare_profile_context()` loads lessons. Post-session: `profile_write_journal` records reflections. See `lib/profile.sh`.

> **Terminology note:** "Formulas" are TOML issue templates in `formulas/` that orchestrate multi-step agent tasks. Distinct from "processes" in `docs/EVIDENCE-ARCHITECTURE.md`.

## Tech stack

- **Shell**: bash (all agents are bash scripts)
- **AI**: `claude -p` (one-shot) or `claude` (interactive/tmux sessions)
- **CI**: Woodpecker CI (queried via REST API + Postgres)
- **VCS**: Forgejo (git + Gitea-compatible REST API)
- **Notifications**: Forge activity (PR/issue comments), OpenClaw heartbeats

## Coding conventions

- All scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Source shared environment: `source "$(dirname "$0")/../lib/env.sh"`
- Log to `$LOGFILE` using the `log()` function from env.sh or defined locally
- Never hardcode secrets — agent secrets come from `.env.enc`, vault secrets from `.env.vault.enc` (or `.env`/`.env.vault` fallback)
- Never embed secrets in issue bodies, PR descriptions, or comments — use env var references (e.g. `$BASE_RPC_URL`)
- ShellCheck must pass (CI runs `shellcheck` on all `.sh` files)
- Avoid duplicate code — shared helpers go in `lib/`

## How to lint and test

```bash
# ShellCheck all scripts
git ls-files '*.sh' | xargs shellcheck

# Run phase protocol test
bash dev/phase-test.sh
```

---

## Agents

| Agent | Directory | Role | Guide |
|-------|-----------|------|-------|
| Dev | `dev/` | Issue implementation | [dev/AGENTS.md](dev/AGENTS.md) |
| Review | `review/` | PR review | [review/AGENTS.md](review/AGENTS.md) |
| Gardener | `gardener/` | Backlog grooming | [gardener/AGENTS.md](gardener/AGENTS.md) |
| Supervisor | `supervisor/` | Health monitoring | [supervisor/AGENTS.md](supervisor/AGENTS.md) |
| Planner | `planner/` | Strategic planning | [planner/AGENTS.md](planner/AGENTS.md) |
| Predictor | `predictor/` | Infrastructure pattern detection | [predictor/AGENTS.md](predictor/AGENTS.md) |
| Architect | `architect/` | Strategic decomposition | [architect/AGENTS.md](architect/AGENTS.md) |

> **Vault:** Being redesigned as a PR-based approval workflow (issues #73-#77).
> See [docs/VAULT.md](docs/VAULT.md) for the vault PR workflow details.

See [lib/AGENTS.md](lib/AGENTS.md) for the full shared helper reference.

---

## Issue lifecycle and label conventions

Issues flow: `backlog` → `in-progress` → PR → CI → review → merge → `closed`.

### Labels

| Label | Meaning | Set by |
|---|---|---|
| `backlog` | Issue is queued for implementation. Dev-poll picks the first ready one. | Planner, gardener, humans |
| `priority` | Queue tier above plain backlog. Issues with both `priority` and `backlog` are picked before plain `backlog` issues. FIFO within each tier. | Planner, humans |
| `in-progress` | Dev-agent is actively working on this issue. Only one issue per project is in-progress at a time. | dev-agent.sh (claims issue) |
| `blocked` | Issue is stuck — agent session failed, crashed, timed out, or CI exhausted. Diagnostic comment on the issue has details. Also used for unmet dependencies. | dev-agent.sh, dev-poll.sh (on failure) |
| `tech-debt` | Pre-existing issue flagged by AI reviewer, not introduced by a PR. | review-pr.sh (auto-created follow-ups) |
| `underspecified` | Dev-agent refused the issue as too large or vague. | dev-poll.sh (on preflight `too_large`), dev-agent.sh (on mid-run `too_large` refusal) |
| `bug-report` | Issue describes user-facing broken behavior with reproduction steps. Separate triage track for reproduction automation. | Gardener (bug-report detection in grooming) |
| `vision` | Goal anchors — high-level objectives from VISION.md. | Planner, humans |
| `prediction/unreviewed` | Unprocessed prediction filed by predictor. | predictor-run.sh |
| `prediction/dismissed` | Prediction triaged as DISMISS — planner disagrees, closed with reason. | Planner (triage-predictions step) |
| `prediction/actioned` | Prediction promoted or dismissed by planner. | Planner (triage-predictions step) |

### Dependency conventions

Issues declare dependencies in their body using a `## Dependencies` or
`## Depends on` section listing `#N` references. The dev-poll scheduler uses
`lib/parse-deps.sh` to extract these and only picks issues whose dependencies
are all closed.

### Single-threaded pipeline

Each project processes one issue at a time. Dev-poll will not start new work
while an open PR is waiting for CI or review. This keeps context clear and
prevents merge conflicts between concurrent changes.

---

## Addressables

Concrete artifacts the factory has produced or is building. The gardener
maintains this table during grooming — see `formulas/run-gardener.toml`.

| Artifact | Location | Observable? |
|----------|----------|-------------|
| Website  | disinto.ai | No |
| Repo     | codeberg.org/johba/disinto | Partial |
| Skill    | ClawHub (in progress) | No |
| GitHub org | github.com/Disinto | No |

## Observables

Addressables with measurement wired — the factory can read structured
feedback from these. The gardener promotes addressables here once an
evidence process is connected.

None yet.

---

## Architecture Decisions

Humans write these. Agents read and enforce them.

| ID | Decision | Rationale |
|---|---|---|
| AD-001 | Nervous system runs from cron, not PR-based actions. | Planner, predictor, gardener, supervisor run directly via `*-run.sh`. They create work, they don't become work. (See PR #474 revert.) |
| AD-002 | Single-threaded pipeline per project. | One dev issue at a time. No new work while a PR awaits CI or review. Prevents merge conflicts and keeps context clear. |
| AD-003 | The runtime creates and destroys, the formula preserves. | Runtime manages worktrees/sessions/temp. Formulas commit knowledge to git before signaling done. |
| AD-004 | Event-driven > polling > fixed delays. | Never `waitForTimeout` or hardcoded sleep. Use phase files, webhooks, or poll loops with backoff. |
| AD-005 | Secrets via env var indirection, never in issue bodies. | Issue bodies become code. Agent secrets go in `.env.enc`, vault secrets in `.env.vault.enc` (both SOPS-encrypted). Referenced as `$VAR_NAME`. Runner gets only vault secrets; agents get only agent secrets. |
| AD-006 | External actions go through vault dispatch, never direct. | Agents build addressables; only the vault exercises them (publishes, deploys, posts). Tokens for external systems (`GITHUB_TOKEN`, `CLAWHUB_TOKEN`, deploy keys) live only in `.env.vault.enc` and are injected into the ephemeral runner container. `lib/env.sh` unsets them so agents never hold them. PRs with direct external actions without vault dispatch get REQUEST_CHANGES. (Vault redesign in progress: PR-based approval on ops repo, see #73-#77) |

**Who enforces what:**
- **Gardener** checks open backlog issues against ADs during grooming; closes violations with a comment referencing the AD number.
- **Planner** plans within the architecture; does not create issues that violate ADs.
- **Dev-agent** reads AGENTS.md before implementing; refuses work that violates ADs.

---

## Phase-Signaling Protocol

When running as a persistent tmux session, Claude must signal the orchestrator
at each phase boundary by writing to a phase file (e.g.
`/tmp/dev-session-{project}-{issue}.phase`).

Key phases: `PHASE:awaiting_ci` → `PHASE:awaiting_review` → `PHASE:done`.
Also: `PHASE:escalate` (needs human input), `PHASE:failed`.

See [docs/PHASE-PROTOCOL.md](docs/PHASE-PROTOCOL.md) for the complete spec
including the orchestrator reaction matrix, sequence diagram, and crash recovery.
