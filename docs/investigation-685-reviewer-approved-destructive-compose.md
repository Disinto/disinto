# Investigation: Reviewer approved destructive compose rewrite in PR #683

**Issue**: #685
**Date**: 2026-04-11
**PR under investigation**: #683 (fix: config: gardener=1h, architect=9m, planner=11m)

## Summary

The reviewer agent approved PR #683 in ~1 minute without flagging that it
contained a destructive rewrite of `docker-compose.yml` — dropping named
volumes, bind mounts, env vars, restart policy, and security options. Six
structural gaps in the review pipeline allowed this to pass.

## Root causes

### 1. No infrastructure-file-specific review checklist

The review formula (`formulas/review-pr.toml`) has a generic review checklist
(bugs, security, imports, architecture, bash specifics, dead code). It has
**no special handling for infrastructure files** — `docker-compose.yml`,
`Dockerfile`, CI configs, or `entrypoint.sh` are reviewed with the same
checklist as application code.

Infrastructure files have a different failure mode: a single dropped line
(a volume mount, an env var, a restart policy) can break a running deployment
without any syntax error or linting failure. The generic checklist doesn't
prompt the reviewer to check for these regressions.

**Fix applied**: Added step 3c "Infrastructure file review" to
`formulas/review-pr.toml` with a compose-specific checklist covering named
volumes, bind mounts, env vars, restart policy, and security options.

### 2. No scope discipline

Issue #682 asked for ~3 env var changes + `PLANNER_INTERVAL` plumbing — roughly
10-15 lines across 3-4 files. PR #683's diff rewrote the entire compose service
block (~50+ lines changed in `docker-compose.yml` alone).

The review formula **does not instruct the reviewer to compare diff size against
issue scope**. A scope-aware reviewer would flag: "this PR changes more lines
than the issue scope warrants — request justification for out-of-scope changes."

**Fix applied**: Added step 3d "Scope discipline" to `formulas/review-pr.toml`
requiring the reviewer to compare actual changes against stated issue scope and
flag out-of-scope modifications to infrastructure files.

### 3. Lessons-learned bias toward approval

The reviewer's `.profile/knowledge/lessons-learned.md` contains multiple entries
that systematically bias toward approval:

- "Approval means 'ready to ship,' not 'perfect.'"
- "'Different from how I'd write it' is not a blocker."
- "Reserve request_changes for genuinely blocking concerns."

These lessons are well-intentioned (they prevent nit-picking and false blocks)
but they create a blind spot: the reviewer suppresses its instinct to flag
suspicious-looking changes because the lessons tell it not to block on
"taste-based" concerns. A compose service block rewrite *looks* like a style
preference ("the dev reorganized the file") but is actually a correctness
regression.

**Recommendation**: The lessons-learned are not wrong — they should stay. But
the review formula now explicitly carves out infrastructure files from the
"bias toward APPROVE" guidance, making it clear that dropped infra
configuration is a blocking concern, not a style preference.

### 4. No ground-truth for infrastructure files

The reviewer only sees the diff. It has no way to compare against the running
container's actual volume/env config. When dev-qwen rewrote a 30-line service
block from scratch, the reviewer saw a 30-line addition and a 30-line deletion
with no reference point.

**Recommendation (future work)**: Maintain a `docker/expected-compose-config.yml`
or have the reviewer fetch `docker compose config` output as ground truth when
reviewing compose changes. This would let the reviewer diff the proposed config
against the known-good config.

### 5. Structural analysis blind spot

`lib/build-graph.py` tracks changes to files in `formulas/`, agent directories
(`dev/`, `review/`, etc.), and `evidence/`. It does **not track infrastructure
files** (`docker-compose.yml`, `docker/`, `.woodpecker/`). Changes to these
files produce no alerts in the graph report — the reviewer gets no
"affected objectives" signal for infrastructure changes.

**Recommendation (future work)**: Add infrastructure file tracking to
`build-graph.py` so that compose/Dockerfile/CI changes surface in the
structural analysis.

### 6. Model and time budget

Reviews use Sonnet (`CLAUDE_MODEL="sonnet"` at `review-pr.sh:229`) with a
15-minute timeout. The PR #683 review completed in ~1 minute. Sonnet is
optimized for speed, which is appropriate for most code reviews, but
infrastructure changes benefit from the deeper reasoning of a more capable
model.

**Recommendation (future work)**: Consider escalating to a more capable model
when the diff includes infrastructure files (compose, Dockerfiles, CI configs).

## Changes made

1. **`formulas/review-pr.toml`** — Added two new review steps:
   - **Step 3c: Infrastructure file review** — When the diff touches
     `docker-compose.yml`, `Dockerfile*`, `.woodpecker/`, or `docker/`,
     requires checking for dropped volumes, bind mounts, env vars, restart
     policy, security options, and network config. Instructs the reviewer to
     read the full file (not just the diff) and compare against the base branch.
   - **Step 3d: Scope discipline** — Requires comparing the actual diff
     footprint against the stated issue scope. Flags out-of-scope rewrites of
     infrastructure files as blocking concerns.

## What would have caught this

With the changes above, the reviewer would have:

1. Seen step 3c trigger for `docker-compose.yml` changes
2. Read the full compose file and compared against the base branch
3. Noticed the dropped named volumes, bind mounts, env vars, restart policy
4. Seen step 3d flag that a 3-env-var issue produced a 50+ line compose rewrite
5. Issued REQUEST_CHANGES citing specific dropped configuration
