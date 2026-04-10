# Lessons learned

## Debugging & Diagnostics

**Map the environment before changing code.** Silent failures often stem from runtime assumptions—missing paths, wrong user context, or unmet prerequisites. Verify the actual environment first.

**Silent termination is a logging failure.** When a script exits non-zero with no output, the bug is in error handling, not the command. Log at operation entry points, not just on success.

**Pipefail is not a silver bullet.** It propagates exit codes but doesn't guarantee visibility. Pair with explicit error logging for external commands (git, curl, etc.).

**Debug the pattern, not the symptom.** If one HTTP call fails with 403, audit all similar calls. If one script has the same bug, find where it's duplicated.

## Shell Scripting Patterns

**Exit codes don't indicate output.** Commands like `grep -c` exit 1 when count is 0 but still output a number. Test both output and exit status independently.

**The `||` pattern is fragile.** It appends on failure, doesn't replace output. Use command grouping or conditionals when output clarity matters.

**Arithmetic contexts are unforgiving.** `(( ))` fails on anything non-numeric. A stray newline or extra digit breaks everything.

**Source file boundaries matter.** Variables defined in sourced files are local unless exported. Trace the lifecycle: definition → export → usage.

## Environment & Deployment

**User context matters at every layer.** When using `gosu`/`su-exec`, ensure all file operations occur under the target user. Create resources with explicit `chown` before dropping privileges.

**Test under final runtime conditions.** Reproduce the exact user context the application will run under, not just "container runs."

**Fail fast with actionable diagnostics.** Entrypoints should exit immediately on dependency failures with clear messages explaining *why* and *what to do*.

**Throttle retry loops.** Infinite retries without backoff mask underlying problems and look identical to healthy startups.

## API & Integration

**Validate semantic types, not just names.** Don't infer resource type from naming conventions. Explicitly resolve whether an identifier is a user, org, or team before constructing URLs.

**403 errors can signal semantic mismatches.** When debugging auth failures, consider whether the request is going to the wrong resource type.

**Auth failures are rarely isolated.** If one endpoint requires credentials, scan for other unauthenticated calls. Environment assumptions about public access commonly break.

**Test against the most restrictive environment first.** If it works on a locked-down instance, it'll work everywhere.

## State & Configuration

**Idempotency requires state awareness.** Distinguish "needs setup" from "already configured." A naive always-rotate approach breaks reproducibility.

**Audit the full dependency chain.** When modifying shared resources, trace all consumers. Embedded tokens create hidden coupling.

**Check validity, not just existence.** Never assume a credential is invalid just because it exists. Verify expiry, permissions, or other validity criteria.

**Conservative defaults become problematic defaults.** Timeouts and limits should reflect real-world expectations, not worst-case scenarios. When in doubt, start aggressive and fail fast.

**Documentation and defaults must stay in sync.** When a default changes, docs should immediately reflect why.

## Validation & Testing

**Add validation after critical operations.** If a migration commits N commits, verify N commits exist afterward. The extra lines are cheaper than debugging incomplete work.

**Integration tests should cover both paths.** Test org and user scenarios, empty inputs, and edge cases explicitly.

**Reproduce with minimal examples.** Running the exact pipeline with test cases that trigger edge conditions catches bugs early.

**Treat "works locally but not in production" as environmental, not code.** The bug is in assumptions about the runtime, not the logic itself.
