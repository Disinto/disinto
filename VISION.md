# Vision

Disinto is an opinionated, lightweight framework that lets **solo entrepreneurs** automate their software startup — from first commit to market fit.

## Who it's for

Solo founders and small teams building in the **software and crypto** space. People who want to ship a web app or launch a token without hiring a team of ten. Disinto is the team.

## What it does

A solo founder sets the vision and defines quality gates. Disinto derives the backlog and handles the rest:

- **Build**: dev-agent picks up backlog issues, implements in isolated worktrees, opens PRs
- **Review**: review-agent checks PRs against project conventions, approves or requests changes
- **Ship**: CI runs, PRs merge, deployments happen — the vault controls what needs your sign-off
- **Operate**: supervisor monitors health, fixes what it can, escalates what it can't
- **Plan**: planner compares project state against this vision, creates issues for gaps
- **Groom**: gardener maintains the backlog — closes duplicates, promotes tech debt, keeps things moving

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

## Growth goals

- **Attract developers** — the project should be easy to understand, easy to fork, easy to contribute to.
- **Stars and forks** — measure traction through Codeberg/GitHub engagement.
- **Contributors** — lower the barrier to entry. Good docs, clear architecture, working examples.
- **Reference deployments** — showcase real projects built and operated by Disinto.
- **Vault as differentiator** — the quality gate model (vision + vault) is what sets Disinto apart from generic CI/CD. Make it visible and easy to understand.

## Milestones

### Foundation (current)
- Core agent loop working: dev → CI → review → merge
- Supervisor health monitoring
- Planner gap analysis against this vision
- Multi-project support with per-project config (harb, disinto, versi)

### Adoption
- One-command bootstrap for new projects (`disinto init`)
- Documentation site with quickstart, tutorials, architecture guide
- Example project that demonstrates the full lifecycle
- Landing page that communicates the value proposition clearly

### Scale
- ~~Multi-project support (multiple repos, one factory)~~ — done (Foundation)
- Plugin system for custom agents
- Community-contributed formulas for common project types (Next.js, Solidity, Python)
- Hosted option for founders who don't want to run their own VPS
