# Lessons learned

## Remediation & deployment

**Escalate gradually.** Cheapest fix first, re-measure, escalate only if it persists. Single-shot fixes are either too weak or cause collateral damage.

**Parameterize deployment boundaries.** Entrypoint references to a specific project name are config values waiting to escape. `${VAR:-default}` preserves compat and unlocks reuse.

**Fail loudly over silent defaults.** A fatal error with a clear message beats a wrong default that appears to work.

**Audit the whole file when fixing one value.** Hardcoded assumptions cluster. Fixing one while leaving siblings produces multi-commit churn.

## Documentation

**Per-context rewrites, not batch replacement.** Each doc mention sits in a different narrative. Blanket substitution produces awkward text.

**Search for implicit references too.** After keyword matches, check for instructions that assume the old mechanism without naming it.

## Code review

**Approval means "safe to ship," not "how I'd write it."** Distinguish "wrong" from "different" — only the former blocks.

**Scale scrutiny to blast radius.** A targeted fix warrants less ceremony than a cross-cutting refactor.

**Be specific; separate blockers from preferences.** Concrete observations invite fixes; vague concerns invite debate.

**Read diffs top-down: intent, behavior, edge cases.** Verify the change matches its stated goal before examining lines.

## Issue authoring & retry

**Self-contained issue bodies.** The agent reads the body, not comments. On retry, update the body with exact error and fix guidance.

**Clean stale branches before retry.** Old branches trigger recovery on stale code. Close PR, delete branch, relabel.

**Diagnose CI failures externally.** The agent sees pass/fail, not logs. After repeated failures, read logs yourself and put findings in the issue.
