# Vision

Disinto is an opinionated, lightweight framework that lets **solo entrepreneurs** automate their software startup — from first commit to market fit.

## Who it's for

Solo founders and small teams building in the **software and crypto** space. People who want to ship a web app or launch a token without hiring a team of ten. Disinto is the team.

## The factory model

A factory has three primitives:

- **Resources** — what the factory can use: compute, accounts, APIs, human time, money
- **Addressables** — artifacts that exist at a location someone can reach without you handing it to them. A URL, a package name, a contract address. The outbound path.
- **Observables** — addressables with a return path. When someone encounters it, signal flows back. Analytics, events, feedback, transactions. The inbound path.

The factory lifecycle is one loop:

```
Resources → build → Addressable → promote → Observable → learn → build
```

Every project runs this loop. The factory's job is to turn resources into addressables, promote addressables to observables as aggressively as possible, and use observables to learn what to build next.

### The two transitions

A project crosses two thresholds. Each is a fold — dormant capability that activates when preconditions are met, gated by the vault.

**Fold 1 → Fold 2: Addressable exists**
The artifact left your machine. Someone *could* reach it. The factory activates shipping: deploy pipelines, channels, distribution. The vault asks: "Ready to go live?"

**Fold 2 → Fold 3: Observable exists**
Signal flows back. Someone *did* reach it, and you know about it. The factory activates learning: assumption testing, audience variation, signal detection. No separate approval — if measurement is baked in, observation is automatic.

The ideal: every addressable is born observable. Measurement is part of building, not an afterthought. It's not shipped until it's measured.

### What the factory learns

Every product decision encodes an assumption. "We target crypto founders" is an assumption. "CLI-first onboarding" is an assumption. "Open source grows through community" is an assumption. Most are invisible until they're wrong.

Observables surface two things:
- **Assumptions challenged** — "we thought X, data says not-X." Pruning. Stop wasting effort.
- **Signals detected** — "we didn't expect this, but people keep doing Y." Opportunity. Follow the energy.

The second is more valuable. The factory doesn't design experiments to test specific hypotheses. It designs for **maximum contact with reality**: expose to diverse audiences, instrument everything, listen for the unexpected. The signal finds you — you just need to be in enough rooms with your ears open.

### The assistant

The factory has a face: an assistant that talks to the founder. Not a dashboard. Not a CLI. A conversational partner that understands who the founder is and what they don't know.

The assistant's first job is to understand the founder:
- **What they're good at** — a developer who can build anything, a crypto native who understands markets, a designer who sees the product
- **What they've never done** — shipping to real users, setting up CI, writing marketing copy, deploying contracts, talking to customers
- **Where they are in the loop** — building? ready to ship but hesitant? shipping but not measuring? measuring but not acting on signals?

The assistant's second job is to guide the founder through the two fold transitions — because that's where people get stuck:

**Fold 1 → 2 (build → ship):** Building is comfortable. Shipping is scary. The assistant recognizes when addressables exist but the founder isn't shipping — and asks the right question: "Your landing page is done. Who should see it first?" Not lecturing. Not pushing. Asking.

**Fold 2 → 3 (ship → learn):** Shipping feels like the finish line. It isn't. The assistant surfaces what the observables are saying — "12 people visited from HN, 3 from Reddit, one opened an issue asking about Rust support" — and helps the founder see the signals they'd otherwise miss.

The assistant fills the gaps in the founder's process knowledge by doing what they can't and asking about what only they can decide. A developer gets helped with distribution and positioning. A marketer gets helped with infrastructure and testing. A crypto founder gets helped with UX and onboarding.

The assistant's personality adapts. It doesn't explain CI to a senior DevOps engineer. It doesn't explain market segments to a former product manager. It reads the founder and meets them where they are.

## What the factory does

Agents handle the work across the full loop:

- **Build**: dev-agent picks up backlog issues, implements in isolated worktrees, opens PRs
- **Review**: review-agent checks PRs against project conventions, approves or requests changes
- **Ship**: deploy pipelines per artifact profile — auto for static sites, human-gated for mainnet contracts
- **Operate**: supervisor monitors health, fixes what it can, escalates what it can't
- **Plan**: planner tracks resources, addressables, and observables against this vision — creates issues for gaps
- **Predict**: predictor challenges claims — "DONE with zero evidence," "shipped but not measured," "Phase 2 but no return path"
- **Groom**: gardener maintains the backlog — closes duplicates, promotes tech debt, keeps things moving
- **Act**: action agent dispatches formulas — user tests, deploys, content drafts
- **Rent-a-human**: when the last mile needs human hands — App Store submission, Reddit post, mainnet deploy — the factory drafts and the human executes

## Target projects

- **Web applications** — SaaS, dashboards, APIs
- **Cryptocurrency projects** — smart contracts, DeFi protocols, token launches
- **Any repo with a CI pipeline** — if it has tests and builds, Disinto can work it

## Design principles

- **Opinionated over configurable** — good defaults, few knobs. Works out of the box for the common case.
- **Bash over frameworks** — if it can be a shell script, it is. Claude is the only dependency that matters.
- **Pull over push** — agents pull work when ready. No scheduler, no queue, no orchestrator daemon.
- **One PR at a time** — sequential pipeline. Saves compute, avoids merge conflicts, keeps the factory predictable.
- **Self-improving** — when an agent solves a new problem, the lesson is captured for next time.
- **Observable by default** — every addressable should be born with a return path. Measurement is part of building.
- **Meet them where they are** — the factory adapts to the founder's strengths and fills the gaps in their knowledge.

## Growth goals

- **Attract developers** — the project should be easy to understand, easy to fork, easy to contribute to.
- **Stars and forks** — measure traction through forge/GitHub engagement.
- **Contributors** — lower the barrier to entry. Good docs, clear architecture, working examples.
- **Reference deployments** — showcase real projects built and operated by Disinto.
- **Vault as differentiator** — the quality gate model (vision + vault) is what sets Disinto apart from generic CI/CD. Make it visible and easy to understand.

## Milestones

### Foundation (current)
- Core agent loop working: dev → CI → review → merge
- Supervisor health monitoring
- Planner gap analysis against this vision
- Multi-project support with per-project config
- Knowledge graph for structural defect detection
- Predictor-planner adversarial feedback loop

### Adoption
- One-command bootstrap (`disinto init` → `disinto up`)
- Built-in Forgejo + Woodpecker CI — no external dependencies
- Landing page communicating the value proposition
- Example project demonstrating the full lifecycle

### Ship (Fold 2)
- Deploy profiles per artifact type (static, package, contract)
- Vault-gated fold transitions
- Engagement measurement baked into deploy pipelines
- Rent-a-human for gated channels and platforms
- Assumptions register — every decision logged with its rationale

### Learn (Fold 3)
- Observable-driven planning — planner uses engagement data
- Predictor challenges assumptions against signals
- Audience variation — same product, different rooms
- Signal detection — surfacing the unexpected
- Maximum contact with reality as a design principle
