<!-- last-reviewed: cebcb8c13ab7948fc794f49c379ed34570e45652 -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages eight agents (dev, review,
gardener, supervisor, planner, predictor, action, vault) that pick up issues from forge,
implement them, review PRs, plan from the vision, gate dangerous actions, and
keep the system healthy — all via cron and `claude -p`.

See `README.md` for the full architecture and `BOOTSTRAP.md` for setup.

## Directory layout

```
disinto/
├── dev/           dev-poll.sh, dev-agent.sh, phase-handler.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-run.sh — direct cron executor for run-gardener formula
├── predictor/     predictor-run.sh — daily cron executor for run-predictor formula
├── planner/       planner-run.sh — direct cron executor for run-planner formula
│                  planner/journal/ — daily raw logs from each planner run
├── supervisor/    supervisor-run.sh — formula-driven health monitoring (cron wrapper)
│                  preflight.sh — pre-flight data collection for supervisor formula
│                  supervisor/journal/ — daily health logs from each run
│                  supervisor-poll.sh — legacy bash orchestrator (superseded)
├── vault/         vault-poll.sh, vault-agent.sh, vault-fire.sh — action gating + procurement
├── action/        action-poll.sh, action-agent.sh — operational task execution
├── lib/           env.sh, agent-session.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, guard.sh, mirrors.sh, build-graph.py
├── projects/      *.toml.example — templates; *.toml — local per-box config (gitignored)
├── formulas/      Issue templates (TOML specs for multi-step agent tasks)
└── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md)
```

> **Terminology note:** "Formulas" in this repo are TOML issue templates in `formulas/` that
> orchestrate multi-step agent tasks (e.g., `run-gardener.toml`, `run-planner.toml`). This is
> distinct from "processes" described in `docs/EVIDENCE-ARCHITECTURE.md`, which are measurement
> and mutation pipelines that read external platforms and write structured evidence to git.

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
| Action | `action/` | Operational task execution | [action/AGENTS.md](action/AGENTS.md) |
| Vault | `vault/` | Action gating + resource procurement | [vault/AGENTS.md](vault/AGENTS.md) |

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
| `blocked` | Issue is stuck — agent session failed, crashed, timed out, or CI exhausted. Diagnostic comment on the issue has details. Also used for unmet dependencies. | dev-agent.sh, action-agent.sh, dev-poll.sh (on failure) |
| `tech-debt` | Pre-existing issue flagged by AI reviewer, not introduced by a PR. | review-pr.sh (auto-created follow-ups) |
| `underspecified` | Dev-agent refused the issue as too large or vague. | dev-poll.sh (on preflight `too_large`), dev-agent.sh (on mid-run `too_large` refusal) |
| `vision` | Goal anchors — high-level objectives from VISION.md. | Planner, humans |
| `prediction/unreviewed` | Unprocessed prediction filed by predictor. | predictor-run.sh |
| `prediction/dismissed` | Prediction triaged as DISMISS — planner disagrees, closed with reason. | Planner (triage-predictions step) |
| `prediction/actioned` | Prediction promoted or dismissed by planner. | Planner (triage-predictions step) |
| `action` | Operational task for the action-agent to execute via formula. | Planner, humans |

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
| AD-001 | Nervous system runs from cron, not action issues. | Planner, predictor, gardener, supervisor run directly via `*-run.sh`. They create work, they don't become work. (See PR #474 revert.) |
| AD-002 | Single-threaded pipeline per project. | One dev issue at a time. No new work while a PR awaits CI or review. Prevents merge conflicts and keeps context clear. |
| AD-003 | The runtime creates and destroys, the formula preserves. | Runtime manages worktrees/sessions/temp. Formulas commit knowledge to git before signaling done. |
| AD-004 | Event-driven > polling > fixed delays. | Never `waitForTimeout` or hardcoded sleep. Use phase files, webhooks, or poll loops with backoff. |
| AD-005 | Secrets via env var indirection, never in issue bodies. | Issue bodies become code. Agent secrets go in `.env.enc`, vault secrets in `.env.vault.enc` (both SOPS-encrypted). Referenced as `$VAR_NAME`. Vault-runner gets only vault secrets; agents get only agent secrets. |
| AD-006 | External actions go through vault dispatch, never direct. | Agents build addressables; only the vault exercises them (publishes, deploys, posts). Tokens for external systems (`GITHUB_TOKEN`, `CLAWHUB_TOKEN`, deploy keys) live only in `.env.vault.enc` and are injected into the ephemeral vault-runner container. `lib/env.sh` unsets them so agents never hold them. PRs with direct external actions without vault dispatch get REQUEST_CHANGES. |

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
