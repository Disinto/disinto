<!-- last-reviewed: 956a24dac7c371bb95c57a1bad03e84ce2a456fd -->
# Supervisor Agent

**Role**: Health monitoring and auto-remediation, executed as a formula-driven
bash agent (#1681). Collects system and project metrics via a bash pre-flight
script and auto-fixes everything it can handle directly (direct remedies,
incident files, daily journal). Abnormal signals that no direct script can
handle are escalated to an interactive Claude session (sonnet) only when
`SUPERVISOR_LLM_ESCALATION=on`; with the default `off` those recipes are named
in a log line and left for a human, and the run exits on the fast path. When
blocked on external resources or human decisions, files vault items instead of
escalating directly.

**Trigger**: `supervisor-run.sh` is invoked by one polling loop, in the agents container (`docker/agents/entrypoint.sh`), on the SUPERVISOR_INTERVAL cadence (default 20 min, #1388). Controlled by the `supervisor` role in `AGENT_ROLES` (included in the default seven-role set since P1/#801).

It sources `lib/guard.sh` and calls `check_active supervisor` first — skips if `$FACTORY_ROOT/state/.supervisor-active` is absent. Then runs a recipe evaluation preflight (`evaluate-recipes.sh`): if no abnormal signals requiring LLM are detected, the run exits early (fast path). Otherwise the LLM escalation gate (#1681) decides: with `SUPERVISOR_LLM_ESCALATION=on`, runs `claude -p` via `agent-sdk.sh`, injects `formulas/run-supervisor.toml` with pre-collected metrics as context, and cleans up on completion or timeout; with `off` (default) or unset, names the left-for-a-human recipes in a log line and the run takes the fast path (direct remedies, journal, incidents, exit 0).

**Key files**:
- `supervisor/supervisor-run.sh` — Polling loop participant + orchestrator: lock, memory guard,
  ops clone sync (`ensure_ops_repo`, #2069: fetch, checkout of the primary branch, ff-only pull; never fatal),
  runs preflight.sh, sources disinto project config, runs claude -p via agent-sdk.sh,
  injects formula prompt with metrics, handles crash recovery. **Repair tape (#1408, #1533, #1636, #1637, #1638)**: `repair_direct_dispatch()` writes a repair proposal (`emit_repair_proposal` → `repair_state_put`, empty `caused_by`) right before it runs a direct recipe's script, unless one is open (`incident` recipes write none), pairing each script run with a tape `tape_run`
  (open, then close with status completed/failed, organ=supervisor, agent=bash) under
  the recipe's repair proposal id; the condition's state entry keeps `acted` and `acted_at`, and `repair_tape_tick` writes the outcome `{acted, cleared}` once the condition stops firing within `SUPERVISOR_REPAIR_WINDOW_S` (default 3600) or the window passes (#1637). `repair_tape_tick` runs only when the recipe evaluation is trustworthy — `RECIPE_EVAL_OK=1`, set when the evaluator exits 0 with a non-empty JSON object carrying a `fired` array — so a failed or non-JSON evaluation leaves state entries open instead of closing them as cleared (#1713). A non-zero script exit never interrupts the tick. When the LLM escalation gate runs a session (`SUPERVISOR_LLM_ESCALATION=on`, #1681), it first writes a `diagnose` repair proposal for the fired conditions and exports its id as `TAPE_PROPOSAL_ID`; the tick logic of #1637 writes its outcome (#1638). A failed outcome append leaves that condition in the repair state file so the next tick retries (#1702).
  A failing direct fix logs `direct action <name> (<script>) failed, rc=<n>: <last stderr line>` (#1697). **Stop rule (#2053)**: before it looks up the proposal, `repair_direct_dispatch` asks `repair_suspended <recipe>` (`lib/repair-suspend.sh`). Once ≥ `suspend_at` of the recipe's last `window` tried outcomes failed (acted, not cleared) and the last one failed, the script does not run and the tick logs `suspended: <recipe>`; while suspended it runs once per `trial_days` (`trial: <recipe>`), and a cleared try lifts it. Thresholds come from the ops pack `packs/repair.toml`; without the pack the rule is off (`docs/design/proposal-loop.md` §5). The first tick of a suspension writes `${TAPE_DIR}/repair/<recipe>.suspended` and queues one owner notice through `lib/notice.sh` (#2031); the lift removes the marker and logs `suspension lifted: <recipe>` (#2054). When the rule cannot evaluate (no pack, no tape: `repair_suspended` prints nothing), a recipe with a marker stays suspended and its script does not run (`stop rule unreadable: <recipe> stays suspended`); only an evaluated, not-suspended result lifts it (#2076). The same tick drafts `claims/can-fix-<recipe>.toml` as an ops PR under the supervisor's account (`lib/repair-claim.sh`, #2055); the lift drafts its revision, so the claim is checked afresh.
- `supervisor/preflight.sh` — Data collection: system resources (RAM, disk, swap,
  load) plus the `Disk owner:` (#2077): box, neighbours or unknown, from the machine
  report (`/srv/disinto/machine/machine.json`, #2070), Docker status, active sessions + phase files, lock files, agent log
  tails, CI pipeline status, open PRs, issue counts, stale worktrees, blocked
  issues, public endpoints (`PUBLIC_URLS`; DOWN after 2 failing ticks in a row), unregistered Nomad services (from the snapshot state). Also performs **stale phase cleanup**: scans `/tmp/*-session-*.phase`
  files for `PHASE:escalate` entries and auto-removes any whose linked issue
  is confirmed closed (24h grace period after closure to avoid races). Reports
  **stale crashed worktrees** (worktrees preserved after crash) — supervisor
  housekeeping removes them after 24h. Collects **Woodpecker agent health**
  (added #933): the newest agent contact from the Woodpecker API (`wp_agent_last_contact_age`, healthy within `WP_AGENT_CONTACT_MAX_S`, default 300 s), fast-failure pipeline count (<60s, last 15 min),
  and overall health verdict (healthy/unhealthy). An unhealthy verdict files an incident: the supervisor cannot restart a Nomad allocation (#1698). Reports
  **research runs** (added #1322): in-flight count + per-run ages (heartbeat)
  from the run ledger at `${OPS_REPO_ROOT}/runs`, artifacts disk %, and oldest
  open `judgment`-labeled issue age — the "Research Runs" section is omitted
  when the ledger directory is absent (not a failure).
- `supervisor/evaluate-recipes.sh` — Rule evaluation against the preflight
  output: `disk_pct_gt` does not fire when the disk owner is `neighbours`:
  the box cannot free space other projects use (#2077). When it fires with an
  owner line present, the owner text joins the evidence.
- `formulas/run-supervisor.toml` — Execution spec: six steps (preflight review,
  health-assessment, decide-actions, report, incidents, journal) with `needs`
  dependencies. Claude evaluates all metrics and takes actions in a single
  interactive session. Health-assessment now includes P2 **Woodpecker agent
  unhealthy** classification (newest agent contact older than
  `WP_AGENT_CONTACT_MAX_S`, default 300 s, or ≥3 fast-failure pipelines/15m)
  and research-run findings from the preflight
  "Research Runs" section (added #1322): P1 artifacts disk > 80%, P2 in-flight
  run older than 70 min, P3 oldest open judgment issue older than 4 h;
  P1 public endpoint DOWN after 2 failing ticks (`## Public Endpoints`, #1923);
  P1 unregistered Nomad service (`## Nomad Services`: MISSING, #1927);
  decide-actions documents the pre-session auto-recovery path
- `supervisor/write-incident.sh` — Writes one markdown incident file per fired
  recipe (P0–P2 only) under `${OPS_REPO_ROOT}/incidents/`. Sources
  `lib/secret-scan.sh` for redaction; graceful exit in degraded mode.
- `supervisor/commit-incidents.sh` — Commits and pushes incident markdown files
  to the ops repo after the Claude session writes them.
- `$OPS_REPO_ROOT/knowledge/*.md` — Domain-specific remediation guides (memory,
  disk, CI, git, dev-agent, review-agent, forge)

**Log sinks**: `supervisor-run.sh`'s internal structured logging goes to
`data/logs/supervisor/supervisor.log`; the polling loop's redirect (#1388)
writes the invocation's stdout/stderr to the same `data/logs/supervisor/supervisor.log`.
#1150 unified the *internal* logging on the `supervisor/` path after the
dual-sink incident — do not introduce a second internal path.

**Alert priorities**: P0 (memory crisis), P1 (disk, public endpoint down), P1 (unregistered Nomad service), P2 (factory stopped/stalled),
P3 (degraded PRs, circular deps, stale deps), P4 (housekeeping).

**Environment variables consumed**:
- `FORGE_TOKEN`, `FORGE_SUPERVISOR_TOKEN` (falls back to FORGE_TOKEN), `FORGE_REPO`, `FORGE_API`, `PROJECT_NAME`, `PROJECT_REPO_ROOT`, `OPS_REPO_ROOT`
- `PRIMARY_BRANCH`, `CLAUDE_MODEL` (set to sonnet by supervisor-run.sh)
- `SUPERVISOR_LLM_ESCALATION` (default `off`/unset: bash-only; `on`: the LLM
  escalation path via `claude -p`)
- `WOODPECKER_TOKEN`, `WOODPECKER_SERVER`, `WOODPECKER_DB_PASSWORD`, `WOODPECKER_DB_USER`, `WOODPECKER_DB_HOST`, `WOODPECKER_DB_NAME` — CI database queries

**Degraded mode (Issue #544)**: When `OPS_REPO_ROOT` is not set or the directory doesn't exist, the supervisor runs in degraded mode:
- Uses bundled knowledge files from `$FACTORY_ROOT/knowledge/` instead of ops repo playbooks
- Writes journal locally to `$FACTORY_ROOT/state/supervisor-journal/` (not committed to git)
- Files vault items locally to `$PROJECT_REPO_ROOT/vault/pending/`
- Logs a WARNING message at startup indicating degraded mode

**Lifecycle**: supervisor-run.sh (started by the polling loop on the SUPERVISOR_INTERVAL cadence, #1388; `check_active supervisor`)
→ lock + memory guard → **CI circuit breaker** (issue #557): reconcile `.dev-active` against incident PR state — open incident PR removes `.dev-active` (pause dev agents); no incident + green canary restores `.dev-active` (resume) → run preflight.sh (collect metrics) → **recipe evaluation**
(`evaluate-recipes.sh`): if all fired recipes have `action: direct` with valid `action_script`
and none require LLM, skip to journal + exit (fast path); otherwise, **LLM escalation
gate** (#1681): with `SUPERVISOR_LLM_ESCALATION=off` (default), name the
left-for-a-human recipes in a log line and fall through to the fast path (direct
remedies, journal, incidents, exit 0); with `on`, load formula + context → run
claude -p via agent-sdk.sh → Claude assesses health, evaluates recipes, auto-fixes,
writes journal → `incidents` step writes markdown files for fired P0–P2 recipes
→ `commit-incidents.sh` commits and pushes to ops repo → `PHASE:done`.
