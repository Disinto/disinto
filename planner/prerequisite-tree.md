# Prerequisite Tree
<!-- Last updated: 2026-03-26 -->

## Objective: One-command bootstrap — `disinto init` (#393)
- [x] Core agent loop stable (Foundation)
- [x] Multi-project support (Foundation)
- [x] Guard allows formula agents in worktrees (#487)
- [x] Bundled dust cleanup — set-euo-pipefail (#516)
- [x] Agent-session.sh pre-register worktree trust (#514)
- [x] Bootstrap hardening — Forgejo INSTALL_LOCK (#634), su-exec (#635), admin user (#636), DNS (#637), crontab (#638), auth (#652), remote target (#653), token creation (#658)
- [x] Agents container reaches Forgejo — env.sh override (#660)
- [x] Woodpecker CI wiring during init (#661)
- [x] End-to-end init smoke test (#668)
Status: DONE — all prerequisites resolved, init fully functional

## Objective: Documentation site with quickstart (#394)
- [x] disinto init working (#393)
Status: DONE — #394 closed

## Objective: Metrics dashboard (#395)
- [x] disinto init working (#393)
- [x] Supervisor formula stable
Status: DONE — #395 closed

## Objective: Example project demonstrating full lifecycle (#466)
- [x] disinto init working (#393)
- [ ] Human decision on implementation approach (external repo vs local demo) — blocked-on-vault
Status: BLOCKED — bounced by dev-agent (too large), routed to vault for human decision

## Objective: Landing page communicating value proposition (#534)
- [x] disinto init working (#393)
- [x] Documentation site live (#394)
- [x] Planner-created issues retain labels reliably (#535)
Status: DONE — #534 closed

## Objective: Autonomous PR merge pipeline (#568)
- [x] PreToolUse guard allows merge API calls from phase-handler (#568)
Status: DONE — #568 closed

## Objective: Unified escalation path (#510)
- [x] PHASE:escalate replaces PHASE:needs_human (supersedes #465)
Status: DONE — #510 closed

## Objective: Vault as procurement gate + RESOURCES.md inventory (#504)
- [x] RESOURCES.md exists
- [x] Vault poll scripts deployed (vault-poll.sh)
Status: DONE — #504 closed

## Objective: Factory operational reliability
- [x] check_active guard logs when skipping (#663)
- [x] Supervisor cleans stale PHASE:escalate files (#664)
Status: DONE — both fixes merged

## Objective: Exec agent — interactive executive assistant (#699)
- [x] Matrix bot infrastructure
- [x] CHARACTER.md personality definition
- [x] exec-session.sh implementation
Status: DONE — #699 closed

## Objective: Rent-a-human — formula-dispatchable human action drafts (#679)
- [x] Formula infrastructure (run-rent-a-human.toml)
- [x] Vault gating for human actions
Status: DONE — #679 closed

## Objective: Skill package distribution (#710 → #711 → #712)
- [ ] Create disinto skill package — SKILL.md + helper scripts (#710) — in backlog, priority
- [ ] Publish to ClawHub registry (#711) — in backlog, depends on #710
- [ ] Submit to secondary registries (#712) — in backlog, depends on #711
- [ ] Evaluate MCP server wrapper (#713) — in backlog, independent
- Note: #714, #715 flagged as duplicates of #710, #711 — pending gardener cleanup
Status: READY — no blocking prerequisites

## Objective: Observable addressables — engagement measurement (#718)
- [ ] Lightweight analytics on disinto.ai (#718) — in backlog
- [ ] Deploy formula verifies measurement is live
- [ ] Planner consumes engagement data
Status: READY — Ship milestone, Fold 2 → Fold 3 bridge
