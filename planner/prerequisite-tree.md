# Prerequisite Tree
<!-- Last updated: 2026-03-25 -->

## Objective: One-command bootstrap — `disinto init` (#393)
- [x] Core agent loop stable (Foundation)
- [x] Multi-project support (Foundation)
- [x] Guard allows formula agents in worktrees (#487)
- [x] Bundled dust cleanup — set-euo-pipefail (#516)
- [x] Agent-session.sh pre-register worktree trust (#514)
- [x] Bootstrap hardening — Forgejo INSTALL_LOCK (#634), su-exec (#635), admin user (#636), DNS (#637), crontab (#638), auth (#652), remote target (#653), token creation (#658)
- [ ] Agents container reaches Forgejo — env.sh override (#660) — in-progress
- [ ] Woodpecker CI wiring during init (#661) — in backlog
- [ ] End-to-end init smoke test (#668) — in backlog
Status: DONE (code merged) — hardening fixes landing, smoke test pending

## Objective: Documentation site with quickstart (#394)
- [x] disinto init working (#393)
Status: DONE — #394 closed

## Objective: Metrics dashboard (#395)
- [x] disinto init working (#393)
- [x] Supervisor formula stable
Status: DONE — #395 closed

## Objective: Example project demonstrating full lifecycle (#466)
- [x] disinto init working (#393)
- [ ] Human decision on implementation approach (external repo vs local demo) ⚠ escalated — awaiting human decision
Status: BLOCKED — bounced by dev-agent (too large), escalated by gardener (2026-03-23), awaiting human decision

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
- [ ] check_active guard logs when skipping (#663) — in backlog
- [ ] Supervisor cleans stale PHASE:escalate files (#664) — in backlog
Status: BLOCKED — 2 prerequisites unresolved
