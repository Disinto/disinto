<!-- last-reviewed: 834c1bceb7b3b0dca2cd5e29a5ffc37633f7566c -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages ten agents (dev, review,
gardener, supervisor, planner, predictor, architect, reproduce, triage, edge
dispatcher) that pick up issues from forge, implement them, review PRs, plan
from the vision, and keep the system healthy — all via a polling loop (`docker/agents/entrypoint.sh`) and `claude -p`.
The dispatcher executes formula-based operational tasks.

Each agent has a `.profile` repository on Forgejo that stores lessons learned
from prior sessions, providing continuous improvement across runs. The
`lib/profile.sh` module manages the `.profile` repo lifecycle: cloning/pulling,
lazy journal→digest→lessons-learned flow, and per-session journal writing.

> **Note:** The vault is being redesigned as a PR-based approval workflow on the
> ops repo (see issues #73-#77). See [docs/VAULT.md](docs/VAULT.md) for details. Old vault scripts are being removed.

See `README.md` for the full architecture and `disinto-factory/SKILL.md` for setup.

## Directory layout

See [docs/AGENTS.md](docs/AGENTS.md) for the full directory tree.

Key directories:
- **Agent dirs**: `dev/`, `review/`, `gardener/`, `supervisor/`, `planner/`, `predictor/`, `architect/` — each has a `*-run.sh` executor and `AGENTS.md`
- **lib/**: Shared helpers (env.sh, secrets.sh, forge-setup.sh, etc.)
- **nomad/jobs/**: Nomad job HCL configs
- **formulas/**: TOML issue templates for multi-step agent tasks
- **docker/**: Dockerfiles and edge container (Caddy, chat, voice, chat-skills, dispatcher)
- **tools/**: Operational tools (vault provisioning, edge-control, acceptance test runner)
- **bin/**: The `disinto` CLI script; snapshot collectors (snapshot-agents.sh, snapshot-forge.sh, snapshot-inbox.sh, snapshot-nomad.sh, snapshot-daemon.sh — use Nomad HTTP API, not CLI)
- **action-vault/**: Vault item validation and examples
- **docs/**: Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md)
- **disinto-ops/**: Ops repo (vault workflow, sprints, knowledge, evidence)

## Agent .profile Model

Each agent has a `.profile` repository on Forgejo storing `knowledge/lessons-learned.md` (injected into each session prompt) and `journal/` reflection entries (digested into lessons). Pre-session: `profile_prepare_context()` loads lessons. Post-session: `profile_write_journal` records reflections. Lazy digestion triggers when undigested journal count exceeds `PROFILE_DIGEST_THRESHOLD`. See `lib/profile.sh`.

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
- Never hardcode secrets — agent secrets come from `.env.enc`, vault secrets from `secrets/<NAME>.enc` (age-encrypted, one file per key)
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

| Agent | Directory | Role | Details |
|-------|-----------|------|---------|
| Dev | `dev/` | Issue implementation | [AGENTS.md](dev/AGENTS.md) |
| Review | `review/` | PR review | [AGENTS.md](review/AGENTS.md) |
| Gardener | `gardener/` | Backlog grooming (per-iteration, single task per cycle, llama-friendly — #872) | [AGENTS.md](gardener/AGENTS.md) |
| Supervisor | `supervisor/` | Health monitoring | [AGENTS.md](supervisor/AGENTS.md) |
| Planner | `planner/` | Strategic planning | [AGENTS.md](planner/AGENTS.md) |
| Predictor | `predictor/` | Infrastructure patterns | [AGENTS.md](predictor/AGENTS.md) |
| Architect | `architect/` | Sprint decomposition | [AGENTS.md](architect/AGENTS.md) |
| Filer | `lib/sprint-filer.sh` | Sub-issue filing (deferred, #779) | — |
| Reproduce | `docker/reproduce/` | Bug reproduction (Playwright MCP) | — |
| Triage | `docker/reproduce/` | Root cause analysis | — |
| Edge dispatcher | `docker/edge/` | Vault action dispatch | — |
| Local-model | `docker/agents/` | Llama-server agents | — |

> **Vault:** Being redesigned as a PR-based approval workflow (issues #73-#77).
> See [docs/VAULT.md](docs/VAULT.md) for details.

Shared helpers: [lib/AGENTS.md](lib/AGENTS.md) · Nomad jobs: [nomad/AGENTS.md](nomad/AGENTS.md)

---

## Issue lifecycle and label conventions

Issues flow: `backlog` → `in-progress` → PR → CI → review → merge → `awaiting-live-verification` → human verifies AC on live box → `closed`.

### Labels

| Label | Meaning | Set by |
|---|---|---|
| `backlog` | Issue is queued for implementation. Dev-poll picks the first ready one. | Planner, gardener, humans |
| `priority` | Queue tier above plain backlog. Issues with both `priority` and `backlog` are picked before plain `backlog` issues. FIFO within each tier. | Planner, humans |
| `in-progress` | Dev-agent is actively working on this issue. Only one issue per project is in-progress at a time. Also set on vision issues by filer-bot when sub-issues are filed (#764). | dev-agent.sh (claims issue), filer-bot (vision issues) |
| `blocked` | Issue is stuck — agent session failed, crashed, timed out, or CI exhausted. Diagnostic comment on the issue has details. Also used for unmet dependencies. | dev-agent.sh, dev-poll.sh (on failure) |
| `tech-debt` | Pre-existing issue flagged by AI reviewer, not introduced by a PR. | review-pr.sh (auto-created follow-ups) |
| `underspecified` | Dev-agent refused the issue as too large or vague. | dev-poll.sh (on preflight `too_large`), dev-agent.sh (on mid-run `too_large` refusal) |
| `bug-report` | Issue describes user-facing broken behavior with reproduction steps. Separate triage track for reproduction automation. | Gardener (bug-report detection in grooming) |
| `in-triage` | Bug reproduced but root cause not obvious — triage agent investigates. Set alongside `bug-report`. | reproduce-agent (when reproduction succeeds but cause unclear) |
| `rejected` | Issue formally rejected — cannot reproduce, out of scope, or invalid. | reproduce-agent, humans |
| `vision` | Goal anchors — high-level objectives from VISION.md. | Planner, humans |
| `prediction/unreviewed` | Unprocessed prediction filed by predictor. | predictor-run.sh |
| `prediction/dismissed` | Prediction triaged as DISMISS — planner disagrees, closed with reason. | Planner (triage-predictions step) |
| `prediction/actioned` | Prediction promoted or dismissed by planner. | Planner (triage-predictions step) |
| `formula` | Issue is a formula-based operational task. Dev-poll skips these; dispatcher handles them. | Dispatcher (when dispatching formula tasks) |
| `awaiting-live-verification` | Issue has been merged but acceptance criteria have not yet been verified on the live box. Dev-poll skips these. | dev-agent (post-merge) |

### Dependency conventions

Issues declare dependencies via `## Dependencies` / `## Depends on` sections listing `#N` refs. `lib/parse-deps.sh` extracts these; dev-poll only picks issues whose deps are all closed. See AD-002 for concurrency bounds per LLM backend.

---

## Addressables and Observables

Concrete artifacts the factory has produced or is building. Observables have measurement wired — the gardener promotes addressables once an evidence process is connected.

| Artifact | Location | Observable? |
|----------|----------|-------------|
| Website  | disinto.ai | No |
| Repo     | codeberg.org/johba/disinto | Partial |
| Skill    | ClawHub (in progress) | No |
| GitHub org | github.com/Disinto | No |

---

## Architecture Decisions

Humans write these. Agents read and enforce them.

| ID | Decision | Rationale |
|---|---|---|
| AD-001 | Nervous system runs from a polling loop (`docker/agents/entrypoint.sh`), not PR-based actions. | Planner, predictor, gardener, supervisor run directly via `*-run.sh`. They create work, they don't become work. (See PR #474 revert.) |
| AD-002 | **Concurrency is bounded per LLM backend, not per project.** One concurrent Claude session per OAuth credential pool; one concurrent session per llama-server instance. | **(a) Anthropic OAuth** — each container uses per-session `CLAUDE_CONFIG_DIR`; native lockfile handles contention. (Rollback: `CLAUDE_EXTERNAL_LOCK=1`.) **(b) llama-server** — finite VRAM, one KV cache; parallel inference thrashes cache → OOM. All llama agents serialize. **(c) Disjoint backends parallelize freely.** `disinto-agents` (Anthropic) runs concurrently with `disinto-agents-llama` (llama). **(d) Per-project safety** enforced by `issue_claim` + per-issue worktrees (separate from this AD). |
| AD-003 | The runtime creates and destroys, the formula preserves. | Runtime manages worktrees/sessions/temp. Formulas commit knowledge to git before signaling done. |
| AD-004 | Event-driven > polling > fixed delays. | Never `waitForTimeout` or hardcoded sleep. Use phase files, webhooks, or poll loops with backoff. |
| AD-005 | Secrets via env var indirection, never in issue bodies. | Issue bodies become code. Agent secrets go in `.env.enc` (SOPS-encrypted), vault secrets in `secrets/<NAME>.enc` (age-encrypted, one file per key). Referenced as `$VAR_NAME`. Runner gets only vault secrets; agents get only agent secrets. |
| AD-006 | External actions go through vault dispatch, never direct. | Agents build addressables; only the vault exercises them (publishes, deploys, posts). Tokens for external systems (`GITHUB_TOKEN`, `CLAWHUB_TOKEN`, deploy keys) live only in `secrets/<NAME>.enc` and are decrypted into the ephemeral runner container. `lib/env.sh` unsets them so agents never hold them. PRs with direct external actions without vault dispatch get REQUEST_CHANGES. (Vault redesign in progress: PR-based approval on ops repo, see #73-#77) |

**Who enforces what:**
- **Gardener** checks open backlog issues against ADs during grooming. **Planner** plans within the architecture.
- **Dev-agent** reads AGENTS.md before implementing; refuses work that violates ADs.
- **AD-002 is a runtime invariant** — OAuth concurrency handled by `CLAUDE_CONFIG_DIR` isolation; violations manifest as 401 or VRAM OOM in logs.

## Phase-Signaling Protocol

When running as a persistent tmux session, Claude must signal the orchestrator at each phase boundary by writing to a phase file (e.g. `/tmp/dev-session-{project}-{issue}.phase`).

Key phases: `PHASE:awaiting_ci` → `PHASE:awaiting_review` → `PHASE:done`. Also: `PHASE:escalate` (needs human input), `PHASE:failed`.
See [docs/PHASE-PROTOCOL.md](docs/PHASE-PROTOCOL.md) for the complete spec, orchestrator reaction matrix, sequence diagram, and crash recovery.
