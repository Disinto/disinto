# Bootstrapping a New Project

How to point disinto at a new target project and get all four agents running.

## Prerequisites

Before starting, ensure you have:

- [ ] A **Codeberg repo** with at least one issue labeled `backlog`
- [ ] A **Woodpecker CI** pipeline (`.woodpecker/` dir with at least one `.yml`)
- [ ] A **second Codeberg account** for the review bot (branch protection requires reviews from a different user)
- [ ] A **local clone** of the target repo on the same machine as disinto
- [ ] `claude` CLI installed and authenticated (`claude --version`)

## 1. Configure `.env`

```bash
cp .env.example .env
```

Fill in:

```bash
# ── Target project ──────────────────────────────────────────
CODEBERG_REPO=org/project              # Codeberg slug
PROJECT_REPO_ROOT=/home/you/project    # absolute path to local clone
PRIMARY_BRANCH=main                    # main or master

# ── Auth ────────────────────────────────────────────────────
# CODEBERG_TOKEN=                      # or use ~/.netrc (machine codeberg.org)
REVIEW_BOT_TOKEN=tok_xxxxxxxx         # the second account's API token

# ── Woodpecker CI ───────────────────────────────────────────
WOODPECKER_TOKEN=tok_xxxxxxxx
WOODPECKER_SERVER=http://localhost:8000
WOODPECKER_REPO_ID=2                  # numeric — find via Woodpecker UI or API

# Woodpecker Postgres (for direct pipeline queries)
WOODPECKER_DB_PASSWORD=secret
WOODPECKER_DB_USER=woodpecker
WOODPECKER_DB_HOST=127.0.0.1
WOODPECKER_DB_NAME=woodpecker

# ── Optional: Matrix notifications ──────────────────────────
# MATRIX_HOMESERVER=http://localhost:8008
# MATRIX_BOT_USER=@factory:your.server
# MATRIX_TOKEN=
# MATRIX_ROOM_ID=

# ── Tuning ──────────────────────────────────────────────────
CLAUDE_TIMEOUT=7200                   # seconds per Claude invocation
```

## 2. Prepare the Target Repo

### Required: CI pipeline

The repo needs at least one Woodpecker pipeline. Dark-factory monitors CI status to decide when a PR is ready for review and when it can merge.

### Required: `CLAUDE.md`

Create a `CLAUDE.md` in the repo root. This is the context document that dev-agent and review-agent read before working. It should cover:

- **What the project is** (one paragraph)
- **Tech stack** (languages, frameworks, DB)
- **How to build/run/test** (`npm install`, `npm test`, etc.)
- **Coding conventions** (import style, naming, linting rules)
- **Project structure** (key directories and what lives where)

The dev-agent reads this file via `claude -p` before implementing any issue. The better this file, the better the output.

### Required: Issue labels

Create two labels on the Codeberg repo:

| Label | Purpose |
|-------|---------|
| `backlog` | Issues ready to be picked up by dev-agent |
| `in-progress` | Managed by dev-agent (auto-applied, auto-removed) |

Optional but recommended:

| Label | Purpose |
|-------|---------|
| `tech-debt` | Gardener can promote these to `backlog` |
| `blocked` | Dev-agent marks issues with unmet dependencies |

### Required: Branch protection

On Codeberg, set up branch protection for your primary branch:

- **Require pull request reviews**: enabled
- **Required approvals**: 1 (from the review bot account)
- **Restrict push**: only allow merges via PR

This ensures dev-agent can't merge its own PRs — it must wait for review-agent (running as the bot account) to approve.

### Required: Seed the `AGENTS.md` tree

The planner-agent maintains an `AGENTS.md` tree — architecture docs with
per-file `<!-- last-reviewed: SHA -->` watermarks. You must seed this before
the first planner run, otherwise the planner sees no watermarks and treats the
entire repo as "new", generating a noisy first-run diff.

1. **Create `AGENTS.md` in the repo root** with a one-page overview of the
   project: what it is, tech stack, directory layout, key conventions. Link
   to sub-directory AGENTS.md files.

2. **Create sub-directory `AGENTS.md` files** for each major directory
   (e.g. `frontend/AGENTS.md`, `backend/AGENTS.md`). Keep each under ~200
   lines — architecture and conventions, not implementation details.

3. **Set the watermark** on line 1 of every AGENTS.md file to the current HEAD:
   ```bash
   SHA=$(git rev-parse --short HEAD)
   for f in $(find . -name "AGENTS.md" -not -path "./.git/*"); do
     sed -i "1s/^/<!-- last-reviewed: ${SHA} -->\n/" "$f"
   done
   ```

4. **Symlink `CLAUDE.md`** so Claude Code picks up the same file:
   ```bash
   ln -sf AGENTS.md CLAUDE.md
   ```

5. Commit and push. The planner will now see 0 changes on its first run and
   only update files when real commits land.

See `planner/planner-agent.sh` for the full AGENTS.md conventions.

## 3. Write Good Issues

Dev-agent works best with issues that have:

- **Clear title** describing the change (e.g., "Add email validation to customer form")
- **Acceptance criteria** — what "done" looks like
- **Dependencies** — reference blocking issues with `#NNN` in the body or a `## Dependencies` section:
  ```
  ## Dependencies
  - #4
  - #7
  ```

Dev-agent checks that all referenced issues are closed (= merged) before starting work. If any are open, the issue is skipped and checked again next cycle.

## 4. Install Cron

```bash
crontab -e
```

Add (adjust paths):

```cron
FACTORY_ROOT=/home/you/disinto

# Supervisor — health checks, auto-healing (every 10 min)
0,10,20,30,40,50 * * * * $FACTORY_ROOT/factory/factory-poll.sh

# Review agent — find unreviewed PRs (every 10 min, offset +3)
3,13,23,33,43,53 * * * * $FACTORY_ROOT/review/review-poll.sh

# Dev agent — find ready issues, implement (every 10 min, offset +6)
6,16,26,36,46,56 * * * * $FACTORY_ROOT/dev/dev-poll.sh

# Gardener — backlog grooming (daily)
15 8 * * *                $FACTORY_ROOT/gardener/gardener-poll.sh

# Planner — AGENTS.md maintenance + gap analysis (weekly)
0 9 * * 1                 $FACTORY_ROOT/planner/planner-poll.sh
```

The 3-minute offsets prevent agents from competing for resources.

## 5. Verify

```bash
# Should complete with "all clear" (no problems to fix)
bash factory/factory-poll.sh

# Should list backlog issues (or "no backlog issues")
bash dev/dev-poll.sh

# Should find no unreviewed PRs (or review one if exists)
bash review/review-poll.sh
```

Check logs after a few cycles:

```bash
tail -30 factory/factory.log
tail -30 dev/dev-agent.log
tail -30 review/review.log
```

## 6. Optional: Matrix Notifications

If you want real-time notifications and human-in-the-loop escalation:

1. Set `MATRIX_*` vars in `.env`
2. Install the listener as a systemd service:
   ```bash
   sudo cp lib/matrix_listener.service /etc/systemd/system/
   sudo systemctl enable --now matrix_listener
   ```
3. The factory and gardener will post status updates and escalation threads to the configured room. Reply in-thread to answer escalations.

## Lifecycle

Once running, the system operates autonomously:

```
You write issues (with backlog label)
  → dev-poll finds ready issues
    → dev-agent implements in a worktree, opens PR
      → CI runs (Woodpecker)
        → review-agent reviews, approves or requests changes
          → dev-agent addresses feedback (if any)
            → merge, close issue, clean up

Meanwhile:
  factory-poll monitors health, kills stale processes, manages resources
  gardener grooms backlog: closes duplicates, promotes tech-debt, escalates ambiguity
  planner rebuilds AGENTS.md from git history, gap-analyses against VISION.md
```

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Dev-agent not picking up issues | `cat /tmp/dev-agent.lock` — is another instance running? Issues labeled `backlog`? Dependencies met? |
| PR not getting reviewed | `tail review/review.log` — CI must pass first. Review bot token valid? |
| CI stuck | `bash lib/ci-debug.sh` — check Woodpecker. Rate-limited? (exit 128 = wait 15 min) |
| Claude not found | `which claude` — must be in PATH. Check `lib/env.sh` adds `~/.local/bin`. |
| Merge fails | Branch protection misconfigured? Review bot needs write access to the repo. |
| Memory issues | Factory auto-heals at <500 MB free. Check `factory/factory.log` for P0 alerts. |
