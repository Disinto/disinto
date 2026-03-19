# Evidence Architecture — Roadmap

> **Status:** Design document. Describes the target architecture for evidence-driven decision making in disinto. Nothing described here exists yet unless marked ✅.

Disinto is purpose-built for one loop: **build software, launch it, improve it, reach market fit.**

This document describes how autonomous agents will sense the world, produce evidence, and use that evidence to make decisions — from "which issue to work on next" to "is this ready to deploy."

## The Loop

```
build → measure → evidence good enough?
  no  → improve → build again
  yes → deploy → measure in-market → evidence still good?
    no  → improve → build again
    yes → expand
```

Every decision in this loop will be driven by evidence, not intuition. The planner will read structured evidence across all dimensions, identify the weakest one, and focus there.

## Evidence as Integration Layer

Different domains have different platforms:

| Domain | Platform | What it tracks | Status |
|--------|----------|---------------|--------|
| Code | Codeberg | Issues, PRs, reviews | ✅ Live |
| CI/CD | Woodpecker | Build/test results | ✅ Live |
| Protocol | Ponder / GraphQL | On-chain state, trades, positions | ✅ Live (not yet wired to evidence) |
| Infrastructure | DigitalOcean / system stats | CPU, RAM, disk, containers | Supervisor monitors, no evidence output yet |
| User experience | Playwright personas | Conversion, friction, journey completion | ✅ Scripts exist (`run-usertest.sh`), no evidence output yet |
| Funnel | Analytics (future) | Bounce rate, conversion, retention | Not started |

Agents won't need to understand each platform. **Processes act as adapters** — they will read a platform's API and write structured evidence to git.

```
[Google Analytics] ──→ measure-funnel process ──→ evidence/funnel/YYYY-MM-DD.json
[Ponder GraphQL]  ──→ measure-protocol process ──→ evidence/protocol/YYYY-MM-DD.json
[System stats]    ──→ measure-resources process ──→ evidence/resources/YYYY-MM-DD.json
[Playwright]      ──→ run-user-test process ──→ evidence/user-test/YYYY-MM-DD.json
```

The planner will read `evidence/` — not Analytics, not Ponder, not DigitalOcean. Evidence is the normalized interface between the world and decisions.

> **Terminology note:** "Process" here means a self-contained measurement or mutation pipeline — distinct from disinto's existing "formulas" (TOML issue templates that guide the dev-agent through multi-step implementation work). Processes produce evidence; formulas produce code. Whether processes reuse the TOML formula format or need their own mechanism is an open design question.

## Process Types

### Sense processes (read-only)

Will produce evidence. Change nothing. Safe to run anytime.

| Process | Measures | Platform | Status |
|---------|----------|----------|--------|
| `run-holdout` | Code quality against blind scenarios | Playwright + docker stack | ✅ `evaluate.sh` exists (harb #977) |
| `run-user-test` | UX quality across 5 personas | Playwright + docker stack | ✅ `run-usertest.sh` exists (harb #978) |
| `measure-resources` | Infra state (CPU, RAM, disk, containers) | System / DigitalOcean API | Not started |
| `measure-protocol` | On-chain health (floor, reserves, volume) | Ponder GraphQL | Not started |
| `measure-funnel` | User conversion and retention | Analytics API | Not started |

### Mutation processes (create change)

Will produce new artifacts. Consume significant resources. Results delivered via PR.

| Process | Produces | Consumes | Status |
|---------|----------|----------|--------|
| `run-evolution` | Better optimizer candidates (`.push3` programs) | CPU-heavy: transpile + compile + deploy + attack per candidate | ✅ `evolve.sh` exists (harb #975) |
| `run-red-team` | Evidence (floor held?) + new attack vectors | CPU + RAM for revm evaluation | ✅ `red-team.sh` exists (harb #976) |

### Feedback loops

Mutation processes will feed each other:

```
red-team discovers attack → new vector added to attacks/ via PR
  → evolution scores candidates against harder attacks
    → better optimizers survive
      → red-team runs again against improved candidates
```

The planner won't need to know this loop exists as a rule. It will emerge from evidence: "new attack vectors landed since last evolution run → evolution scores are stale → run evolution."

## Evidence Directory

> **Not yet created.** See harb #973 for the implementation issue.

```
evidence/
  evolution/        # Run params, generation stats, best fitness, champion
  red-team/         # Per-attack results, floor held/broken, ETH extracted
  holdout/          # Per-scenario pass/fail, gate decision
  user-test/        # Per-persona reports, friction points
  resources/        # CPU, RAM, disk, container state
  protocol/         # On-chain metrics from Ponder
  funnel/           # Analytics conversion data (future)
```

Each file will be dated JSON. Machine-readable. Git history will show trends. The planner will diff against previous runs to detect improvement or regression.

## Delivery Pattern

Every process will follow the same delivery contract:

1. **Evidence** (metrics/reports) → committed to `evidence/` on main
2. **Artifacts** (code changes, new attack vectors, evolved programs) → PR
3. **Summary** → issue comment with key metrics and link to evidence file

## Evidence-Gated Deployment

Deployment will not be a human decision or a calendar event. It will be the natural consequence of all evidence dimensions being green:

- **Holdout:** 90% scenarios pass
- **Red-team:** Floor holds on all known attacks
- **User-test:** All personas complete journey, newcomers convert
- **Evolution:** Champion fitness above threshold
- **Protocol metrics:** ETH reserve growing, floor ratcheting up
- **Funnel:** Bounce rate below target, conversion above target

When all dimensions pass their thresholds, deployment becomes the obvious next action. Until then, the planner will know **which dimension is weakest** and focus resources there.

## Resource Allocation

The planner will optimize resource allocation across all processes. When the box is idle, it will find the highest-value use of compute based on evidence staleness and current gaps.

Sense processes are cheap — run them freely to keep evidence fresh.
Mutation processes are expensive — run them when evidence justifies the cost.

The planner will read evidence recency and decide:
- "Red-team results are from before the VWAP fix → re-run"
- "User-tests haven't run since February → stale"
- "Evolution scored against 4 attacks but we now have 6 → outdated"
- "Box is idle, no CI running → good time for evolution"

No schedules. No hardcoded rules. The planner's judgment, informed by evidence.

## What Disinto Is Not

Disinto is not a general-purpose company operating system. It does not model arbitrary resources or business processes.

It is finely tuned for one thing: **money → software product → customer contact → knowledge → product improvement → market fit → more money.**

Every agent, process, and evidence type serves this loop.

## Related Issues

- harb #973 — Evidence directory structure
- harb #974 — Red-team attack vector auto-promotion
- harb #975 — `run-evolution` process
- harb #976 — `run-red-team` process
- harb #977 — `run-holdout` process
- harb #978 — `run-user-test` process
- disinto #139 — Action agent (process executor)
- disinto #140 — Prediction agent (evidence reader)
- disinto #142 — Planner triages predictions
