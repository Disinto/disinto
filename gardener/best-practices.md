# Gardener Best Practices

## What the gardener does
Keeps the issue backlog clean so the dev-agent always has well-structured work.
Runs daily (or 2x/day). Light touch — grooming, not development.

## Issue quality checklist
A "ready" issue has:
- [ ] Clear title (feat/fix/refactor prefix)
- [ ] Acceptance criteria with checkboxes
- [ ] Affected files listed
- [ ] Dependencies section (if any)
- [ ] No duplicate in the backlog

## When to close
- **Duplicate**: newer issue closed, comment links to older one
- **Superseded**: explicitly replaced by another issue (link it)
- **Stale + irrelevant**: no activity 14+ days AND no longer makes sense given current state
- **Completed elsewhere**: work was done in another PR without referencing the issue

## When to escalate (NEVER decide these)
- Issue scope is ambiguous — could be interpreted multiple ways
- Two issues overlap but aren't exact duplicates — need human to pick scope
- Issue contradicts a design decision (check AGENTS.md tree)
- Issue is feature request vs bug — classification matters for priority
- Closing would lose important context that isn't captured elsewhere

## Escalation format
Compact, decision-ready. Human should be able to reply "1a 2c 3b" and be done.

```
🌱 Issue Gardener — 3 items need attention

1. #123 "Push3 gas optimization" — duplicate of #456 "optimizer gas limit"?
   (a) close #123  (b) close #456  (c) keep both, different scope
2. #789 "refactor VWAPTracker" — stale 21 days, VWAP was rewritten in #603
   (a) close as superseded  (b) reopen with updated scope  (c) keep, still relevant
3. #234 "landing page A/B test" — 8 acceptance criteria spanning 4 packages
   (a) split into: UI variants, analytics, config, deployment  (b) keep as-is
```

## What NOT to do
- Don't create new feature issues — gardener grooms, doesn't invent work
- Don't change issue priority/labels beyond adding missing deps
- Don't modify acceptance criteria that are already well-written
- Don't close issues that are actively being worked on (check for open PRs)
- Don't rate-limit yourself — max 10 API calls per run for issue reads, 5 for writes
- **Don't enumerate the process environment.** Never run `env`, `printenv`,
  `set`, `declare`, or `export` with no args (#910). The session's JSONL
  transcript is captured to `${DISINTO_LOG_DIR}/gardener/step.log` on a
  host volume; an unredacted `env` dump exposes loaded `FORGE_*_TOKEN`,
  `VAULT_*`, `GH_*` secrets to anyone with shell on the box. If you must
  inspect a specific var, echo only that var by name. Tokens belong in
  `-H "Authorization: token $FORGE_TOKEN"` curl headers — never in
  stdout, comments, or issue bodies.

## Lessons learned
- Review bot hallucination rate is ~15% — gardener should verify claims about code before acting
- Dev-agent doesn't understand the product — clear acceptance criteria save 2-3 CI cycles
- Feature issues MUST list affected e2e test files
- Issue templates from ISSUE-TEMPLATES.md propagate via triage gate
- **AD-002 is a runtime invariant; nothing for the gardener to check at issue-groom time.** Concurrency is enforced by `flock session.lock` within each container and by `issue_claim` for per-issue work. A violation manifests as a 401 or VRAM OOM in agent logs, not as a malformed issue.
