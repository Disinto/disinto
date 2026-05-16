<!-- last-reviewed: 48e744ad3a103c1c46c690a9edffb0089b9d9615 -->
# Directory Layout Reference

Full directory layout for the disinto factory. See root [AGENTS.md](../AGENTS.md) for the concise overview.

## disinto/ (code repo)

```
disinto/                 (code repo)
├── dev/           dev-poll.sh, dev-agent.sh, phase-test.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-run.sh, gardener-step.sh — polling-loop executors
│                  classify.sh — per-task formula dispatcher
│                  best-practices.md — gardener best-practice reference
│                  dust.jsonl — persistent dust accumulator (JSONL, 30-day TTL)
│                  pending-actions.json — final manifest (JSON array, committed to PR)
│                  actions/ — remediation scripts (cleanup-locks, cleanup-phase-files,
│                           cleanup-worktrees, close-stuck-pr, disk-pressure,
│                           git-rebase-fix, memory-crisis, sweep-ci-exhausted, wp-agent-restart)
├── predictor/     predictor-run.sh — polling-loop executor for run-predictor formula
├── planner/       planner-run.sh — polling-loop executor for run-planner formula
├── supervisor/    supervisor-run.sh — formula-driven health monitoring
│                  preflight.sh, evaluate-recipes.sh, recipes.yaml,
│                  write-incident.sh, commit-incidents.sh
├── architect/     architect-run.sh — strategic decomposition of vision into sprints
├── action-vault/  vault-env.sh — shared env setup (vault redesign in progress, see #73-#77)
│                  SCHEMA.md — vault item schema documentation
│                  validate.sh — vault item validator
│                  examples/ — example vault action TOMLs (promote, publish, release, webhook-call)
├── lib/           env.sh, secrets.sh, agent-sdk.sh, ci-helpers.sh, ci-debug.sh, load-project.sh, parse-deps.sh, guard.sh, mirrors.sh, pr-lifecycle.sh, issue-lifecycle.sh, worktree.sh, formula-session.sh, profile.sh, stack-lock.sh, forge-setup.sh, forge-push.sh, ops-setup.sh, ci-setup.sh, generators.sh, hire-agent.sh, release.sh, build-graph.py, branch-protection.sh, secret-scan.sh, tea-helpers.sh, action-vault.sh, ci-log-reader.py, git-creds.sh, sprint-filer.sh, hvault.sh, backfill-labels.sh, claude-config.sh, backup.sh
│                  hooks/ — Claude Code session hooks
│                  init/nomad/ — cluster-up.sh, install.sh, vault-init.sh, deploy.sh, wp-oauth-register.sh, wp-seed-secrets.sh
├── nomad/         server.hcl, client.hcl, vault.hcl — HCL configs for /etc/nomad.d/ and /etc/vault.d/
│                  jobs/ — forgejo.hcl (Vault secrets, S2.4); woodpecker-server/agent.hcl (host-net, docker.sock, Vault KV, S3.1-S3.2); agents.hcl (7 roles + llama, S4.1); agents-supervisor-opus.hcl (standalone Opus, S4.1); vault-runner.hcl (batch dispatch, S5.3); staging.hcl (Caddy file-server, S5.2); edge.hcl (Caddy proxy + dispatcher, S5.1); edge-threads-gc.hcl (Caddy proxy thread GC, S5.1)
├── projects/      *.toml.example — templates; *.toml — local per-box config (gitignored)
├── formulas/      Issue templates (TOML specs for multi-step agent tasks)
│                  agents-md-stale.toml — per-directory AGENTS.md watermark walk
│                  blocker-starving-the-factory.toml — surface backlog dep blocking factory
│                  bundle-dust.toml — bundle dust accumulator into backlog issues
│                  enrich-bug-report.toml — enrich underspecified bug reports
│                  enrich-underspecified.toml — fill in missing AC for vague issues
│                  file-subissues.toml — file sub-issues from approved ops PRs
│                  pitch-vision.toml — vision pitch template
│                  promote-tech-debt.toml — promote tech-debt issues to backlog
│                  revisit-blocked.toml — revisit stale blocked issues
├── docker/        Dockerfiles: agents, edge, reproduce, runner; chat (server.py, ui/); edge/ (Dockerfile, dispatcher.sh, entrypoint-edge.sh, chat-skills/); voice/ (bridge.py, ui/)
├── tools/         Operational tools: edge-control/ (register.sh, install.sh); run-acceptance.sh — acceptance test runner for CI
│                  comment-on-issue.sh — post comments and manage labels on issues
│                  discover-closed-issues.sh — extract closed issue numbers from PR/merge
│                  migrate-ac-to-file.sh — migrate inline AC to test files
│                  vault-apply-policies.sh, vault-apply-roles.sh, vault-import.sh — Vault provisioning (S2.1/S2.2)
│                  vault-seed-<svc>.sh — per-service Vault secret seeders; auto-invoked by `bin/disinto --with <svc>`
├── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md, AGENTS.md); voice/ (SOUL_VOICE.md — voice agent state machine); contributing/ (acceptance-tests.md)
├── site/          disinto.ai website content; engagement.js — frontend engagement assets
├── tests/         Test files (mock-forgejo.py, smoke-init.sh, lib-hvault.bats, lib-generators.bats, vault-import.bats, disinto-init-nomad.bats)
├── tests/acceptance/  Acceptance test scripts per issue (issue-<n>.sh); runner at tools/run-acceptance.sh; helpers at tests/lib/acceptance-helpers.sh
├── tests/lib/       Shared test helpers (acceptance-helpers.sh)
├── templates/     Issue templates
├── bin/           The `disinto` CLI script (`--with <svc>` deploys services + runs their Vault seeders)
├── disinto-factory/  Setup documentation and skill
├── state/         Runtime state
├── .woodpecker/   Woodpecker CI pipeline configs
│                  ci.yml — main CI pipeline; acceptance-tests.yml — post-merge acceptance verification
│                  check-stale-rebase.sh — stale-base regression guard
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

## Per-directory AGENTS.md files

Each agent directory has its own AGENTS.md with detailed instructions:

- [dev/AGENTS.md](dev/AGENTS.md) — Issue implementation workflow
- [review/AGENTS.md](review/AGENTS.md) — PR review workflow
- [gardener/AGENTS.md](gardener/AGENTS.md) — Backlog grooming workflow
- [supervisor/AGENTS.md](supervisor/AGENTS.md) — Health monitoring workflow
- [planner/AGENTS.md](planner/AGENTS.md) — Strategic planning workflow
- [predictor/AGENTS.md](predictor/AGENTS.md) — Infrastructure prediction workflow
- [architect/AGENTS.md](architect/AGENTS.md) — Sprint decomposition workflow
- [lib/AGENTS.md](lib/AGENTS.md) — Shared helper reference
- [nomad/AGENTS.md](nomad/AGENTS.md) — Nomad job configuration reference
- [vault/policies/AGENTS.md](vault/policies/AGENTS.md) — Vault policy reference
