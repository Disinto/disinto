# disinto stats — Agent-Run Telemetry

Summarise the per-agent-session telemetry that `lib/agent-metrics.sh` (#1101)
appends to `$DISINTO_LOG_DIR/metrics/agent-runs.jsonl` on every finished run.

## Command

```
disinto stats [--since <N>d|<N>h] [--role <role>] [--task <ref>] [--json]
```

| Option | Default | Meaning |
|---|---|---|
| `--since <N>d\|<N>h` | `7d` | Window, measured back from now against each record's `ts`. |
| `--role <role>` | (all) | Restrict to one role (e.g. `dev`, `review`). |
| `--task <ref>` | — | Print every record attributed to an issue/PR number, one per line (leading `#`/`!` stripped). |
| `--json` | — | One machine-readable JSON object instead of the table. |

## Example

```
$ disinto stats
Agent runs — last 7d (5 sessions)
role         runs    ok timeout maxturns other   median      p90   tokens in/out        $    tps compactions/run
dev             4     1       1        1     1    1h00m    2h00m     3.5M / 350K    35.00   11.7             1.5
review          1     1       0        0     0      30m      30m      200K / 20K     3.00   15.0             0.0
totals          5     2       1        1     1                       3.7M / 370K    38.00                    1.2
* 1 session(s) with no duration (killed mid-run) excluded from duration and tps stats
skipped 3 malformed line(s) in /root/data/logs/metrics/agent-runs.jsonl
```

## Column semantics

- `ok` = outcome `success`; `timeout` = `timeout`; `maxturns` = `error_max_turns`;
  anything else (e.g. `no_result`) counts in `other`, which is only shown when non-zero.
- `median` / `p90` are over `duration_ms` for records that have one. Records whose
  duration is null (killed mid-run) still count toward `runs` and the outcome
  columns but are excluded from the duration and tps math, and are footnoted.
- `tokens in/out` are summed input/output tokens; `$` is summed `cost_usd`;
  `tps` is the mean of per-record `output_tps` (nulls ignored);
  `compactions/run` is the mean of per-record `compactions`.
- The `totals` row leaves median/p90/tps blank — they are not meaningful when
  roles with different scales are combined.

## Guarantees

- A missing or empty metrics file prints `no agent runs recorded yet` and exits 0.
- Malformed JSONL lines (e.g. a torn final line from a concurrent writer) are
  skipped and counted, never fatal.
- `--json` emits a single object with the same figures: `window`, `role`,
  `records`, `skipped`, `excluded_no_duration`, `roles[]`, `totals`.
