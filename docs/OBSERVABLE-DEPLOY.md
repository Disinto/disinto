# Observable Deploy Pattern

> Every addressable is born observable. It's not shipped until it's measured.
> — VISION.md

## The pattern

Every deploy formula must verify that the deployed artifact has a **return path**
before marking the deploy complete. An addressable without measurement is Fold 2
without Fold 3 — shipped but not learned from.

## How it works

Deploy formulas add a final `verify-observable` step that checks:

1. **Measurement infrastructure exists** — the mechanism that captures engagement
   data is present and active (log file, analytics endpoint, event stream).
2. **Collection script is in place** — a process exists to transform raw signals
   into structured evidence in `evidence/<domain>/YYYY-MM-DD.json`.
3. **Evidence has been collected** — at least one report exists (or a note that
   the first collection is pending).

The step is advisory, not blocking — a deploy succeeds even if measurement
isn't yet active. But the output makes the gap visible to the planner, which
will file issues to close it.

## Artifact types and their return paths

| Artifact type | Addressable | Measurement source | Evidence path |
|---------------|-------------|-------------------|---------------|
| Static site | URL (disinto.ai) | Caddy access logs | `evidence/engagement/` |
| npm package | Registry name | Download counts API | `evidence/package/` |
| Smart contract | Contract address | On-chain events (Ponder) | `evidence/protocol/` |
| Docker image | Registry tag | Pull counts API | `evidence/container/` |

## Adding observable verification to a deploy formula

Add a `[[steps]]` block after the deploy verification step:

```toml
[[steps]]
id          = "verify-observable"
title       = "Verify engagement measurement is active"
description = """
Check that measurement infrastructure is active for this artifact.

1. Verify the data source exists and is recent
2. Verify the collection script is present
3. Report latest evidence if available

Observable status summary:
  addressable=<what was deployed>
  measurement=<data source>
  evidence=<path to evidence directory>
  consumer=planner (gap analysis)
"""
needs       = ["verify"]
```

## Evidence format

Each evidence file is dated JSON committed to `evidence/<domain>/YYYY-MM-DD.json`.
The planner reads these during gap analysis. The predictor challenges staleness.

Minimum fields for engagement evidence:

```json
{
  "date": "2026-03-26",
  "period_hours": 24,
  "unique_visitors": 42,
  "page_views": 156,
  "top_pages": [{"path": "/", "views": 89}],
  "top_referrers": [{"source": "news.ycombinator.com", "visits": 12}]
}
```

## The loop

```
deploy formula
  → verify-observable step confirms measurement is active
    → collect-engagement.sh (cron) parses logs → evidence/engagement/
      → planner reads evidence → identifies gaps → creates issues
        → dev-agent implements → deploy formula runs again
```

This is the bridge from Fold 2 (ship) to Fold 3 (learn).
