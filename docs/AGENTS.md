<!-- last-reviewed: 68d751dd0b8ef098c6e35cd2e8dc3701c69bdd38 -->
# Directory Layout Reference

Full directory layout for the disinto factory. See root [AGENTS.md](../AGENTS.md) for the concise overview.

## disinto/ (code repo)

```
disinto/                 (code repo)
├── dev/           dev-poll.sh, dev-agent.sh, merge-ready.sh, phase-test.sh — issue implementation
├── review/        review-poll.sh, review-pr.sh — PR review
├── gardener/      gardener-run.sh — one-shot full-formula executor (bare-metal
│                  │                 host cron; started by entrypoint.sh poll)
│                  │                 gardener-step.sh — per-iteration step
│                  │                 executor; not a polling-loop participant —
│                  │                 not started by entrypoint.sh (poll runs
│                  │                 gardener-run.sh only, #1480)
│                  │                 classify.sh — bash-only task classifier
│                  │                 (emits JSON); not on the scheduler
│                  │                 (not started by entrypoint.sh, #1480)
│                  best-practices.md — gardener best-practice reference
│                  dust.jsonl — persistent dust accumulator (JSONL, 30-day TTL)
│                  pending-actions.json — final manifest (JSON array, committed to PR)
│                  pending-actions.jsonl — staging manifest: one action per line,
│                  written by gardener-run.sh, converted to JSON at commit time
├── predictor/     predictor-run.sh — polling-loop executor for run-predictor formula
├── planner/       planner-run.sh — polling-loop executor for run-planner formula
├── supervisor/    supervisor-run.sh — formula-driven health monitoring
│                  preflight.sh, evaluate-recipes.sh, recipes.yaml,
│                  write-incident.sh, commit-incidents.sh
│                  actions/ — remediation scripts (cleanup-locks, cleanup-phase-files,
│                           cleanup-worktrees, disk-pressure,
│                           git-rebase-fix)
├── architect/     architect-run.sh — drafts and revises the sub-issues of ops-repo pitches
├── action-vault/  vault-env.sh — shared env setup (vault redesign in progress, see #73-#77)
│                  SCHEMA.md — vault item schema documentation
│                  validate.sh — vault item validator
│                  examples/ — example vault action TOMLs (promote, publish, release, webhook-call, run-experiment)
│                  policy.toml — per-formula blast-radius tiers read by classify.sh
├── lib/           env.sh, secrets.sh, agent-sdk.sh, ci-helpers.sh, ci-debug.sh,
│                  ci-fix-tracker.sh, load-project.sh, parse-deps.sh, guard.sh,
│                  mirrors.sh, pr-lifecycle.sh, issue-lifecycle.sh, worktree.sh,
│                  formula-session.sh, profile.sh, stack-lock.sh, forge-setup.sh,
│                  forge-push.sh, ops-setup.sh, ci-setup.sh, generators.sh,
│                  hire-agent.sh, release.sh, build-graph.py, branch-protection.sh,
│                  secret-scan.sh, tea-helpers.sh, action-vault.sh, ci-log-reader.py,
│                  git-creds.sh, sprint-filer.sh, hvault.sh, backfill-labels.sh,
│                  claude-config.sh, backup.sh, forge-helpers.sh, inbox-sentinels.sh,
│                  gardener-edit.sh, gardener-pr.sh, stale-base-check.sh,
│                  agent-harness-dsh.sh, agent-metrics.sh, dsh-session.sh, resources.sh,
│                  run-ledger.sh, snapshot-tmp.sh, stats.sh, tape.sh, vault-ssh.sh,
│                  served-model.sh (served_model_id — the model the local server
│                  reports serving, #2014), dsh-seed.sh (dsh_seed_home for one-shot
│                  dsh runs), dsh-oneshot.sh (one headless dsh prompt, #1847),
│                  probe.sh (run a sprint/claim probe and read its number, #1673),
│                  sprint-tape.sh (mint the sprint-level tape proposal, #1618),
│                  sprint-block.sh (parse a milestone's sprint block, #1629),
│                  sprint-milestone.sh (a pitch's sprint milestone, #1911),
│                  claims.sh (read ops-repo claim files, #1640),
│                  catalog-forecast.sh (p_success from the ops catalog, §9.2),
│                  tape-outcome-guard.sh (one merged outcome per proposal, #1737),
│                  ci-first-green.sh (#1877), forge-paginate.sh, forge-api-fallback.sh,
│                  pr-author-filter.sh (#1690), pr-review-feedback.sh (#1688),
│                  pitch.sh / pitch-pr.sh (read + update a pitch on its ops PR, #1906),
│                  table-column.sh (append a column to a markdown table, #1650),
│                  wp-agent-health.sh (newest Woodpecker agent contact, #1698)
│                  hooks/ — Claude Code session hooks (on-compact-reinject, on-idle-stop,
│                  on-phase-change, on-pretooluse-guard, on-session-end, on-stop-failure)
│                  init/nomad/ — cluster-up.sh, install.sh, forgejo-bootstrap.sh,
│                  chat-init.sh, vault-init.sh, vault-engines.sh, vault-nomad-auth.sh,
│                  lib-systemd.sh, systemd-nomad.sh, systemd-vault.sh, deploy.sh,
│                  wp-oauth-register.sh, wp-activate-repo.sh, wp-seed-secrets.sh,
│                  lib-vault-mlock.sh
├── nomad/         server.hcl, client.hcl, vault.hcl — HCL configs for /etc/nomad.d/ and /etc/vault.d/
│                  jobs/ — forgejo.hcl (Vault secrets, S2.4); woodpecker-server.hcl (S3.1); woodpecker-agent.hcl
│                  (host-net, docker.sock, Vault KV, S3.2); agents.hcl (7 roles + llama, S4.1);
│                  agents-supervisor-opus.hcl (standalone Opus, S4.1); vault-runner.hcl (batch
│                  dispatch, S5.3); staging.hcl (Caddy file-server, S5.2); edge.hcl (Caddy proxy
│                  + dispatcher, S5.1); agents-dev-qwen.hcl, agents-gardener-qwen.hcl,
│                  agents-review-qwen.hcl (qwen-backend jobs); agent-logs-rotate.hcl (batch log
│                  rotation); healer.hcl (host-side raw_exec allocation healer running
│                  bin/healer.sh, #1951 — the only deterministic host process allowed to
│                  message the owner directly via bin/notify-owner.sh, AD-006 exception)
│                  acl-policies/chat-ops.hcl — Nomad ACL policy for the chat-Claude control
│                  surface, bound to the token Vault renders into the edge Caddy task (#650)
├── projects/      *.toml.example — templates; *.toml — local per-box config (gitignored)
├── formulas/      Issue templates (TOML specs for multi-step agent tasks).
│                  run-gardener.toml, run-planner.toml, run-predictor.toml, run-supervisor.toml,
│                  run-architect.toml, run-publish-site.toml, run-rent-a-human.toml — formula runners
│                  dev.toml, review-pr.toml, groom-backlog.toml, triage.toml — agent task specs
│                  agents-md-stale.toml, blocker-starving-the-factory.toml, bundle-dust.toml —
│                  gardener task specs
│                  enrich-underspecified.toml, enrich-bug-report.toml, promote-tech-debt.toml —
│                  backlog enrichment specs
│                  file-subissues.toml, pitch-vision.toml, revisit-blocked.toml, release.toml,
│                  reproduce.toml — operational task specs
│                  deploy-drift.toml — deploy-drift check spec; run-experiment.sh —
│                  experiment runner script (wave 2, #1293)
├── docker/        Dockerfiles: reproduce, runner; research/ (experiment runner image, #1293);
│                  edge/ (Caddy + dispatcher + engagement); agents/ (llama-server agents + dsh
│                  headless patches, dsh-settings-llamacpp.yaml /
│                  dsh-settings-xai.yaml — provider settings templates baked into
│                  the image, selected by DSH_PROVIDER at seed time, #2003/#2004)
├── tools/         Operational tools: edge-control/ (register.sh, install.sh,
│                  dispatch.sh, key-command.sh, porter-install.sh, porter-front.sh, porter-caddy.sh, porter-dns.sh, porter-wrap.sh, porter-admin.sh, porter-doctor.sh, porter-tunnel-keys.sh, stripe-webhook.sh; lib/ (ports.sh,
│                  caddy.sh, authorized_keys.sh, accounts.sh, name-verbs.sh,
│                  apply-name.sh); verbs/ (approve.sh, credits.sh, credits-buy.sh,
│                  credits-grant.sh, jev.sh, register-request.sh, revoke.sh, status.sh,
│                  ticket.sh, tickets.sh, whoami.sh); packs/ (scope.json); examples/ (stripe-webhook.caddy);
│                  reserved-name blocklist, admin-approved allowlist, per-caller
│                  attribution); the tunnel user disinto-tunnel keeps a real
│                  home (/home/disinto-tunnel) so sshd StrictModes accepts its
│                  authorized_keys, and porter runs the root-owned
│                  porter-tunnel-keys.sh via a single NOPASSWD drop-in
│                  /etc/sudoers.d/porter-tunnel (mode 440, root-owned) — see
│                  tests/acceptance/issue-1572.sh
│                  run-acceptance.sh — acceptance test runner for CI
│                  jev-scope.sh — factory-side Jev-scope reader (pipes an issue
│                  text to the Porter door and records the three noul readings,
│                  #1598); not called by the dev pick since #1632 (the Jev reading
│                  was dropped from the tape context); pure calibration, never
│                  changes the pick; see dev/AGENTS.md
│                  cut-release.sh — cut a release: bump, tag, push, wait for CI
│                  images, check GHCR visibility (#1228)
│                  check-deploy-drift.sh — verify deployed defaults match the repo
│                  calibration.sh — predicted vs actual over the dev-loop tape (#1393)
│                  claim-proposals.sh — a merged claim becomes a claim-loop proposal (#1641)
│                  tape-rejections.sh — a closed rejected issue the tape does not hold
│                  yet becomes a rejected dev proposal (#1631)
│                  pitch-decisions.sh — a decided pitch reaches the tape; a merged one becomes its milestone and sub-issues (#1891, #1892)
│                  claim-checks.sh — run a proposed claim's check; one miss contradicts it (#1642)
│                  claims-report.sh — catalog table of each claim's status (#1645)
│                  grade.sh — one-command human grading of a proposal (#1410)
│                  pitch-lint.sh — lints a pitch's sub-issue block against notes/issue-writing.md; markdown report; warns on overlap with a backlog list (#1903)
│                  seed-research-labels.sh — idempotently seed research labels on an existing forge
│                  vault-apply-policies.sh, vault-apply-roles.sh, vault-import.sh — Vault
│                  provisioning (S2.1/S2.2)
│                  vault-seed-<svc>.sh — per-service Vault secret seeders; auto-invoked by
│                  `bin/disinto --with <svc>`
│                  sprint-due.sh, sprint-children.sh, sprint-outcomes.sh — sprint
│                  queue queries (#1675, #1674, #1676); tape-stuck.sh — sessions
│                  stuck on a phase, read from the tape (#1648);
│                  migrate-ac-to-file.sh — move an issue's acceptance criteria into
│                  tests/acceptance/issue-<n>.sh; calibration-purpose.sh and
│                  calibration-signatures.sh — Jev-scope calibration readers (#1652,
│                  #1651); sync-nomad-client-config.sh — regenerate the Nomad client
│                  config; xai-login.sh / xai-login.mjs — XAI provider login (#2006);
│                  edge-control/README.md — edge-control operator guide
├── docs/          Protocol docs (PHASE-PROTOCOL.md, EVIDENCE-ARCHITECTURE.md, AGENTS.md,
│                  branch-protection.md, stats.md);
│                  contributing/ (acceptance-tests.md, issues-for-bots.md);
│                  design/ (proposal-loop.md — how the factory proposes, records
│                  and learns; notes/ incl. organs.md, issue-writing.md)
├── site/          disinto.ai website content
├── tests/         Test files (mock-forgejo.py, smoke-init.sh, lib-hvault.bats, lib-generators.bats,
│                  vault-import.bats, disinto-init-nomad.bats)
├── tests/acceptance/  Acceptance test scripts per issue (issue-<n>.sh); runner at
│                  tools/run-acceptance.sh; helpers at tests/lib/acceptance-helpers.sh
├── tests/lib/       Shared test helpers (acceptance-helpers.sh, webhook-route-helpers.sh)
├── templates/     Issue templates
├── bin/           The `disinto` CLI script (multi-command: init, up, secrets, validate, vault,
│                  wp, backup, edge, ci-logs; vault includes reseed-all, reseed-ops-repo,
│                  reseed-runner, reseed-chat-oauth)
│                  agent-log-rotate.sh, factory-walk.sh, healer.sh, notify-owner.sh,
│                  snapshot-agents.sh, snapshot-daemon.sh,
│                  snapshot-forge.sh, snapshot-inbox.sh, snapshot-nomad.sh,
│                  uninstall.sh
├── tape/          Tape records written by lib/tape.sh (#1389); the dev-loop
│                  context pack and failure-signature rubric stubs (#1400) were
│                  removed in #1481. The failure-signature rubric now lives in
│                  the ops repo (rubrics/<loop>.toml, [map] read by
│                  lib/signature.sh signature_for) and outcomes may carry a
│                  signature field (#1607). No context-pack extractor exists.
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
├── runs/          append-only JSON run records (records in git)
├── artifacts/     run payloads by action-id (gitignored; see runs/README.md)
├── campaigns/     planner/architect campaign notes
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
