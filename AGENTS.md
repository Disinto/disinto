<!-- last-reviewed: bdd7faf8966cd7b66a0b77e7693644298242fe5c -->
# Disinto — Agent Instructions

## What this repo is

Disinto is an autonomous code factory: a polling loop (`docker/agents/entrypoint.sh`)
drives ten agents (dev, review, gardener, supervisor, planner, predictor, architect,
reproduce, triage, edge dispatcher) that implement forge issues, review
PRs, plan from the vision, and keep the system healthy — via `claude -p` or tmux
sessions; the edge dispatcher executes formula-based operational tasks.

Each agent has a separate `.profile` repo on Forgejo: lessons-learned.md (injected
into every session prompt) + `journal/` reflections, digested into lessons past
`PROFILE_DIGEST_THRESHOLD`. `lib/profile.sh`: `profile_prepare_context()` (pre-session)
/ `profile_write_journal` (post-session).

Vault: PR-based approval redesign on the ops repo in progress (#73-#77); see `docs/VAULT.md`.

See `README.md` for architecture, `disinto-factory/SKILL.md` for setup.

## Directory layout

Full tree: `docs/AGENTS.md`. Key directories:

- **Agent dirs** (dev, review, gardener, supervisor, planner, predictor, architect) — `*-run.sh` executor + `AGENTS.md` each
- **lib/** — shared shell helpers, see [lib/AGENTS.md](lib/AGENTS.md)
- **formulas/** — TOML templates for multi-step agent tasks; distinct from "processes" (`docs/EVIDENCE-ARCHITECTURE.md`)
- **nomad/jobs/** — Nomad job HCL configs
- **docker/** — Dockerfiles + edge container
- **tools/** — operational tools (vault provisioning, edge-control)
- **bin/** — `disinto` CLI + snapshot-*.sh collectors (Nomad: HTTP API, not CLI)
- **action-vault/** — vault item validation + examples
- **docs/** — protocol docs
- **vault/policies/** — vault HCL policies
- **site/** — frontend assets
- **tests/acceptance/** — post-merge acceptance scripts
- **.woodpecker/** — CI pipelines

## Tech stack

bash (all agents) · `claude -p`/`claude` · Woodpecker CI (REST + Postgres) · Forgejo (Gitea API) · Forge activity + OpenClaw heartbeats.

## Coding conventions

- All scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Source the shared environment: `source "$(dirname "$0")/../lib/env.sh"`
- Log to `$LOGFILE` using the `log()` function (from env.sh or defined locally)
- Never hardcode secrets: agent secrets come from `.env.enc`, vault secrets from `secrets/<NAME>.enc`; reference them as env vars (e.g. `$BASE_RPC_URL`), never in issue bodies, PR descriptions, or comments
- ShellCheck must pass (CI runs it on all `.sh` files)
- Avoid duplicate code — shared helpers go in `lib/`

## How to lint and test

```bash
# ShellCheck all scripts
git ls-files '*.sh' | xargs shellcheck

# Run phase protocol test
bash dev/phase-test.sh
```

## Agents

Per-agent `AGENTS.md`: [dev/](dev/AGENTS.md) (implementation), [review/](review/AGENTS.md) (PR review), [gardener/](gardener/AGENTS.md) (grooming, #872), [supervisor/](supervisor/AGENTS.md) (health), [planner/](planner/AGENTS.md) (planning), [predictor/](predictor/AGENTS.md) (infrastructure patterns), [architect/](architect/AGENTS.md) (sprints). Filer: `lib/sprint-filer.sh` (#779, deferred). Reproduce/Triage: `docker/reproduce/` (Playwright MCP). Edge dispatcher: `docker/edge/`. Local-model: `docker/agents/` (llama). Nomad: [nomad/AGENTS.md](nomad/AGENTS.md).

## Issue lifecycle and labels

Flow: `backlog` → `in-progress` → PR → CI → review → merge → `awaiting-live-verification` → `closed`.

| Label | Meaning | Set by |
|---|---|---|
| `backlog` | Queued for implementation; dev-poll picks the first ready one; re-queue point for transient resource-limit exits (#1164). | Planner, gardener, humans, dev-agent |
| `priority` | Queue tier above plain backlog; FIFO within tier. | Planner, humans |
| `in-progress` | Dev-agent is working it (one per project); also on vision issues when sub-issues are filed (#764). | dev-agent.sh, filer-bot |
| `blocked` | Stuck: no-push crash/failure, CI fixes exhausted, retry budget burned (3rd consecutive resource-limit exit → `no_push_after_3_attempts`), or unmet dependency. A single resource-limit exit is transient → re-queue to `backlog` (#1164); see the diagnostic comment. | dev-agent.sh, dev-poll.sh |
| `waiting-on-compute` | Dispatched, waiting on an external run; dev-poll skips. Removed when the run lands. | Humans, formulas |
| `tech-debt` | Pre-existing issue flagged by the AI reviewer. | review-pr.sh |
| `underspecified` | Refused as too large or vague. | dev-poll.sh, dev-agent.sh |
| `bug-report` | User-facing breakage with repro steps; separate triage track. | Gardener |
| `in-triage` | Reproduced, cause unclear; alongside `bug-report`. | reproduce-agent |
| `rejected` | Cannot reproduce, out of scope, or invalid. | reproduce-agent, humans |
| `vision` | Goal anchors from VISION.md. | Planner, humans |
| `prediction/unreviewed` | Unprocessed prediction. | predictor-run.sh |
| `prediction/dismissed` | Triaged DISMISS (planner disagreed). | Planner |
| `prediction/actioned` | Promoted or dismissed. | Planner |
| `formula` | Operational task; dev-poll skips, dispatcher handles. | Dispatcher |
| `awaiting-live-verification` | Merged, AC unverified on live box; dev-poll skips. | dev-agent |

### Dependency conventions

Issues declare deps via `## Dependencies` / `## Depends on` sections (`#N` refs); `lib/parse-deps.sh` extracts them; dev-poll only claims issues whose deps are all closed. Concurrency bounds: AD-002.

## Addressables and Observables

Artifacts the factory has built or is building; the gardener promotes an addressable once its evidence process is wired: disinto.ai (partial) · codeberg.org/johba/disinto (partial) · ClawHub skill (in progress) · github.com/Disinto.

## Architecture Decisions

Humans write these; agents read and enforce them (dev-agent refuses work that violates them).

| ID | Decision | Rationale |
|---|---|---|
| AD-001 | Nervous system = polling loop (`docker/agents/entrypoint.sh`), not PR-based actions. | Planner, predictor, gardener, supervisor run via `*-run.sh`; they create work, don't become work (PR #474 revert). |
| AD-002 | **Concurrency is bounded per LLM backend, not per project.** | **(a) Anthropic OAuth** — one concurrent Claude session per credential pool; isolate via per-session `CLAUDE_CONFIG_DIR`, native lockfile (rollback: `CLAUDE_EXTERNAL_LOCK=1`). **(b) llama-server** — `--kv-unified` (#1069): shared KV pool, budget = **sum of concurrent sessions' context** vs `--ctx-size`; size each agent's autocompact lane (docs/agents-llama.md). Without `--kv-unified`: one session per instance (parallel inference → cache thrash → OOM). **(c) Disjoint backends parallelize freely.** **(d) Per-project safety** = `issue_claim` + per-issue worktrees. |
| AD-003 | The runtime creates and destroys; the formula preserves. | Runtime manages worktrees/sessions/temp; formulas commit knowledge to git before signaling done. |
| AD-004 | Event-driven > polling > fixed delays. | Never `waitForTimeout` or hardcoded sleep; use phase files, webhooks, or poll loops with backoff. |
| AD-005 | Secrets via env var indirection, never in issue bodies. | Agent secrets: `.env.enc` (SOPS); vault secrets: `secrets/<NAME>.enc` (age, one file per key), referenced as `$VAR_NAME`. Runners get only vault secrets; agents only agent secrets. |
| AD-006 | External actions go through vault dispatch, never direct. | Agents build addressables; only the vault exercises them. External tokens (`GITHUB_TOKEN`, `CLAWHUB_TOKEN`, deploy keys) live only in `secrets/<NAME>.enc`, decrypted into the ephemeral runner; `lib/env.sh` unsets them from agents. PRs acting directly get REQUEST_CHANGES. |

**Who enforces:** gardener checks backlog issues against the ADs; planner plans within them. **AD-002 is a runtime invariant** (violations → 401s / VRAM OOM in logs).

## Phase-Signaling Protocol

Persistent tmux sessions signal phase boundaries by writing a phase file (e.g. `/tmp/dev-session-{project}-{issue}.phase`): `PHASE:awaiting_ci` → `PHASE:awaiting_review` → `PHASE:done`; also `PHASE:escalate` (needs human input), `PHASE:failed`. Full spec: `docs/PHASE-PROTOCOL.md`.
