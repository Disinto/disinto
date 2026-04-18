<!-- last-reviewed: 3fb2de4a8ab500707665adfbf954aa1921ae7775 -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory. It manages ten agents (dev, review,
gardener, supervisor, planner, predictor, architect, reproduce, triage, edge
dispatcher) that pick up issues from forge, implement them, review PRs, plan
from the vision, and keep the system healthy — all via a polling loop (`docker/agents/entrypoint.sh`) and `claude -p`.
The dispatcher executes formula-based operational tasks.

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
├── gardener/      gardener-run.sh — polling-loop executor for run-gardener formula
│                  best-practices.md — gardener best-practice reference
│                  pending-actions.json — queued gardener actions
├── predictor/     predictor-run.sh — polling-loop executor for run-predictor formula
├── planner/       planner-run.sh — polling-loop executor for run-planner formula
├── supervisor/    supervisor-run.sh — formula-driven health monitoring (polling-loop executor)
│                  preflight.sh — pre-flight data collection for supervisor formula
├── architect/     architect-run.sh — strategic decomposition of vision into sprints
├── action-vault/  vault-env.sh — shared env setup (vault redesign in progress, see #73-#77)
│                  SCHEMA.md — vault item schema documentation
│                  validate.sh — vault item validator
│                  examples/ — example vault action TOMLs (promote, publish, release, webhook-call)
├── lib/           env.sh, agent-sdk.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, guard.sh, mirrors.sh, pr-lifecycle.sh, issue-lifecycle.sh, worktree.sh, formula-session.sh, stack-lock.sh, forge-setup.sh, forge-push.sh, ops-setup.sh, ci-setup.sh, generators.sh, hire-agent.sh, release.sh, build-graph.py, branch-protection.sh, secret-scan.sh, tea-helpers.sh, action-vault.sh, ci-log-reader.py, git-creds.sh, sprint-filer.sh, hvault.sh
│                  hooks/ — Claude Code session hooks (on-compact-reinject, on-idle-stop, on-phase-change, on-pretooluse-guard, on-session-end, on-stop-failure)
│                  init/nomad/ — cluster-up.sh, install.sh, vault-init.sh, lib-systemd.sh (Nomad+Vault Step 0 installers, #821-#825); wp-oauth-register.sh (Forgejo OAuth2 app + Vault KV seeder for Woodpecker, S3.3); deploy.sh (dependency-ordered Nomad job deploy + health-wait, S4)
├── nomad/         server.hcl, client.hcl (allow_privileged for woodpecker-agent, S3-fix-5), vault.hcl — HCL configs deployed to /etc/nomad.d/ and /etc/vault.d/ by lib/init/nomad/cluster-up.sh
│                  jobs/ — Nomad jobspecs: forgejo.hcl (Vault secrets via template, S2.4); woodpecker-server.hcl + woodpecker-agent.hcl (host-net, docker.sock, Vault KV, S3.1-S3.2); agents.hcl (7 roles, llama, Vault-templated bot tokens, S4.1); vault-runner.hcl (parameterized batch dispatch, S5.3); staging.hcl (Caddy file-server, dynamic port — edge discovers via service registration, S5.2); chat.hcl (Claude chat UI, tmpfs via mount block, Vault OAuth secrets, S5.2); edge.hcl (Caddy proxy + dispatcher sidecar, S5.1)
├── projects/      *.toml.example — templates; *.toml — local per-box config (gitignored)
├── formulas/      Issue templates (TOML specs for multi-step agent tasks)
├── docker/        Dockerfiles and entrypoints: reproduce, triage, edge dispatcher, chat (server.py, entrypoint-chat.sh, Dockerfile, ui/)
├── tools/         Operational tools: edge-control/ (register.sh, install.sh, verify-chat-sandbox.sh)
│                  vault-apply-policies.sh, vault-apply-roles.sh, vault-import.sh — Vault provisioning (S2.1/S2.2)
│                  vault-seed-<svc>.sh — per-service Vault secret seeders; auto-invoked by `bin/disinto --with <svc>` (add a new file to support a new service)
├── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md)
├── site/          disinto.ai website content
├── tests/         Test files (mock-forgejo.py, smoke-init.sh, lib-hvault.bats, lib-generators.bats, vault-import.bats, disinto-init-nomad.bats)
├── templates/     Issue templates
├── bin/           The `disinto` CLI script (`--with <svc>` deploys services + runs their Vault seeders)
├── disinto-factory/  Setup documentation and skill
├── state/         Runtime state
├── .woodpecker/   Woodpecker CI pipeline configs
├── VISION.md      High-level project vision
└── CLAUDE.md      Claude Code project instructions

disinto-ops/             (ops repo — {project}-ops)
├── vault/
│   ├── actions/   where vault action TOMLs land (core of vault workflow)
│   ├── pending/   vault items awaiting approval
│   ├── approved/  approved vault items
│   ├── fired/     executed vault items
│   └── rejected/  rejected vault items
├── sprints/       sprint planning artifacts
├── knowledge/     shared agent knowledge + best practices
├── evidence/      engagement data, experiment results
├── portfolio.md   addressables + observables
├── prerequisites.md  dependency graph
└── RESOURCES.md   accounts, tokens (refs), infra inventory
```

## Agent .profile Model

Each agent has a `.profile` repository on Forgejo storing `knowledge/lessons-learned.md` (injected into each session prompt) and `journal/` reflection entries (digested into lessons). Pre-session: `formula_prepare_profile_context()` loads lessons. Post-session: `profile_write_journal` records reflections. See `lib/formula-session.sh`.

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

| Agent | Directory | Role | Guide |
|-------|-----------|------|-------|
| Dev | `dev/` | Issue implementation | [dev/AGENTS.md](dev/AGENTS.md) |
| Review | `review/` | PR review | [review/AGENTS.md](review/AGENTS.md) |
| Gardener | `gardener/` | Backlog grooming | [gardener/AGENTS.md](gardener/AGENTS.md) |
| Supervisor | `supervisor/` | Health monitoring | [supervisor/AGENTS.md](supervisor/AGENTS.md) |
| Planner | `planner/` | Strategic planning | [planner/AGENTS.md](planner/AGENTS.md) |
| Predictor | `predictor/` | Infrastructure pattern detection | [predictor/AGENTS.md](predictor/AGENTS.md) |
| Architect | `architect/` | Strategic decomposition (read-only on project repo) | [architect/AGENTS.md](architect/AGENTS.md) |
| Filer | `lib/sprint-filer.sh` | Sub-issue filing from merged sprint PRs | ops repo pipeline (deferred, see #779) |
| Reproduce | `docker/reproduce/` | Bug reproduction using Playwright MCP | `formulas/reproduce.toml` |
| Triage | `docker/reproduce/` | Deep root cause analysis | `formulas/triage.toml` |
| Edge dispatcher | `docker/edge/` | Polls ops repo for vault actions, executes via Claude sessions | `docker/edge/dispatcher.sh` |
| Local-model agents | `docker/agents/` (same image) | Local llama-server agents configured via `[agents.X]` sections in project TOML | [docs/agents-llama.md](docs/agents-llama.md) |

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
| AD-002 | **Concurrency is bounded per LLM backend, not per project.** One concurrent Claude session per OAuth credential pool; one concurrent session per llama-server instance. Containers with disjoint backends may run in parallel. | The single-thread invariant is about *backends*, not pipelines. **(a) Anthropic OAuth credentials race on token refresh** — each container uses a per-session `CLAUDE_CONFIG_DIR`, so Claude Code's native lockfile-based OAuth refresh handles contention automatically without external serialization. (Legacy: set `CLAUDE_EXTERNAL_LOCK=1` to re-enable the old `flock session.lock` wrapper for rollback.) **(b) llama-server has finite VRAM and one KV cache** — parallel inference thrashes the cache and risks OOM. All llama-backed agents serialize on the same lock. **(c) Disjoint backends are free to parallelize.** Today `disinto-agents` (Anthropic OAuth, runs `review,gardener`) runs concurrently with `disinto-agents-llama` (llama, runs `dev`) on the same project — they share neither OAuth state nor llama VRAM. **(d) Per-project work-conflict safety** (no duplicate dev work, no merge conflicts on the same branch) is enforced by `issue_claim` (assignee + `in-progress` label) and per-issue worktrees — that's a separate guard that does NOT depend on this AD. |
| AD-003 | The runtime creates and destroys, the formula preserves. | Runtime manages worktrees/sessions/temp. Formulas commit knowledge to git before signaling done. |
| AD-004 | Event-driven > polling > fixed delays. | Never `waitForTimeout` or hardcoded sleep. Use phase files, webhooks, or poll loops with backoff. |
| AD-005 | Secrets via env var indirection, never in issue bodies. | Issue bodies become code. Agent secrets go in `.env.enc` (SOPS-encrypted), vault secrets in `secrets/<NAME>.enc` (age-encrypted, one file per key). Referenced as `$VAR_NAME`. Runner gets only vault secrets; agents get only agent secrets. |
| AD-006 | External actions go through vault dispatch, never direct. | Agents build addressables; only the vault exercises them (publishes, deploys, posts). Tokens for external systems (`GITHUB_TOKEN`, `CLAWHUB_TOKEN`, deploy keys) live only in `secrets/<NAME>.enc` and are decrypted into the ephemeral runner container. `lib/env.sh` unsets them so agents never hold them. PRs with direct external actions without vault dispatch get REQUEST_CHANGES. (Vault redesign in progress: PR-based approval on ops repo, see #73-#77) |

**Who enforces what:**
- **Gardener** checks open backlog issues against ADs during grooming; closes violations with a comment. **Planner** plans within the architecture; does not create issues that violate ADs.
- **Dev-agent** reads AGENTS.md before implementing; refuses work that violates ADs.
- **AD-002 is a runtime invariant; nothing for the gardener to check at issue-groom time.** OAuth concurrency is handled by per-session `CLAUDE_CONFIG_DIR` isolation (with `CLAUDE_EXTERNAL_LOCK` as a rollback flag). Per-issue work is enforced by `issue_claim`. A violation manifests as a 401 or VRAM OOM in agent logs, not as a malformed issue.

## Phase-Signaling Protocol

When running as a persistent tmux session, Claude must signal the orchestrator at each phase boundary by writing to a phase file (e.g. `/tmp/dev-session-{project}-{issue}.phase`).

Key phases: `PHASE:awaiting_ci` → `PHASE:awaiting_review` → `PHASE:done`. Also: `PHASE:escalate` (needs human input), `PHASE:failed`.
See [docs/PHASE-PROTOCOL.md](docs/PHASE-PROTOCOL.md) for the complete spec, orchestrator reaction matrix, sequence diagram, and crash recovery.
