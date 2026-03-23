# Bootstrapping a New Project

How to point disinto at a new target project and get all agents running.

## Prerequisites

Before starting, ensure you have:

- [ ] A **git repo** (GitHub, Codeberg, or any URL) with at least one issue labeled `backlog`
- [ ] A **Woodpecker CI** pipeline (`.woodpecker/` dir with at least one `.yml`)
- [ ] **Docker** installed (for local Forgejo provisioning) — or a running Forgejo instance
- [ ] A **local clone** of the target repo on the same machine as disinto
- [ ] `claude` CLI installed and authenticated (`claude --version`)
- [ ] `tmux` installed (`tmux -V`) — required for persistent dev sessions (issue #80+)

## Quick Start

The fastest path is `disinto init`, which provisions a local Forgejo instance, creates bot users and tokens, clones the repo, and sets up cron — all in one command:

```bash
disinto init https://github.com/org/repo
```

This will:
1. Start a local Forgejo instance via Docker (at `http://localhost:3000`)
2. Create admin + bot users (dev-bot, review-bot) with API tokens
3. Create the repo on Forgejo and push your code
4. Generate a `projects/<name>.toml` config
5. Create standard labels (backlog, in-progress, blocked, etc.)
6. Install cron entries for the agents

No external accounts or tokens needed.

## 1. Secret Management (SOPS + age)

Disinto encrypts secrets at rest using [SOPS](https://github.com/getsops/sops) with [age](https://age-encryption.org/) encryption. When `sops` and `age` are installed, `disinto init` automatically:

1. Generates an age key at `~/.config/sops/age/keys.txt` (if none exists)
2. Creates `.sops.yaml` pinning the age public key
3. Encrypts all secrets into `.env.enc` (safe to commit)
4. Removes the plaintext `.env`

**Install the tools:**

```bash
# age (key generation)
apt install age          # Debian/Ubuntu
brew install age         # macOS

# sops (encryption/decryption)
# Download from https://github.com/getsops/sops/releases
```

**The age private key** at `~/.config/sops/age/keys.txt` is the single file that must be protected. Back it up securely — without it, `.env.enc` cannot be decrypted. LUKS disk encryption on the VPS protects this key at rest.

**Managing secrets after setup:**

```bash
disinto secrets edit     # Opens .env.enc in $EDITOR, re-encrypts on save
disinto secrets show     # Prints decrypted secrets (for debugging)
disinto secrets migrate  # Converts existing plaintext .env -> .env.enc
```

**Fallback:** If `sops`/`age` are not installed, `disinto init` writes secrets to a plaintext `.env` file with a warning. All agents load secrets transparently — `lib/env.sh` checks for `.env.enc` first, then falls back to `.env`.

## 2. Configure `.env`

```bash
cp .env.example .env
```

Fill in:

```bash
# ── Forge (auto-populated by disinto init) ─────────────────
FORGE_URL=http://localhost:3000        # local Forgejo instance
FORGE_TOKEN=                           # dev-bot token (auto-generated)
FORGE_REVIEW_TOKEN=                    # review-bot token (auto-generated)

# ── Woodpecker CI ───────────────────────────────────────────
WOODPECKER_TOKEN=tok_xxxxxxxx
WOODPECKER_SERVER=http://localhost:8000
# WOODPECKER_REPO_ID — now per-project, set in projects/*.toml [ci] section

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

### Backwards compatibility

If you have an existing deployment using `CODEBERG_TOKEN` / `REVIEW_BOT_TOKEN` in `.env`, those still work — `env.sh` falls back to the old names automatically. No migration needed.

## 3. Configure Project TOML

Each project needs a `projects/<name>.toml` file with box-specific settings
(absolute paths, Woodpecker CI IDs, Matrix credentials, forge URL). These files are
**gitignored** — they are local installation config, not shared code.

To create one:

```bash
# Automatic — generates TOML, clones repo, sets up cron:
disinto init https://github.com/org/repo

# Manual — copy a template and fill in your values:
cp projects/myproject.toml.example projects/myproject.toml
vim projects/myproject.toml
```

The `forge_url` field in the TOML tells all agents where to find the forge API:

```toml
name            = "myproject"
repo            = "org/myproject"
forge_url       = "http://localhost:3000"
```

The repo ships `projects/*.toml.example` templates showing the expected
structure. See any `.toml.example` file for the full field reference.

## 4. Claude Code Global Settings

Configure `~/.claude/settings.json` with **only** permissions and `skipDangerousModePermissionPrompt`. Do not add hooks to the global settings — `agent-session.sh` injects per-worktree hooks automatically.

Match the configuration from harb-staging exactly. The file should contain only permission grants and the dangerous-mode flag:

```json
{
  "permissions": {
    "allow": [
      "..."
    ]
  },
  "skipDangerousModePermissionPrompt": true
}
```

### Seed `~/.claude.json`

Run `claude --dangerously-skip-permissions` once interactively to create `~/.claude.json`. This file must exist before cron-driven agents can run.

```bash
claude --dangerously-skip-permissions
# Exit after it initializes successfully
```

## 5. File Ownership

Everything under `/home/debian` must be owned by `debian:debian`. Root-owned files cause permission errors when agents run as the `debian` user.

```bash
chown -R debian:debian /home/debian/harb /home/debian/dark-factory
```

Verify no root-owned files exist in agent temp directories:

```bash
# These should return nothing
find /tmp/dev-* /tmp/harb-* /tmp/review-* -not -user debian 2>/dev/null
```

## 5b. Woodpecker CI + Forgejo Integration

`disinto init` automatically configures Woodpecker to use the local Forgejo instance as its forge backend if `WOODPECKER_SERVER` is set in `.env`. This includes:

1. Creating an OAuth2 application on Forgejo for Woodpecker
2. Writing `WOODPECKER_FORGEJO_*` env vars to `.env`
3. Activating the repo in Woodpecker

### Manual setup (if Woodpecker runs outside of `disinto init`)

If you manage Woodpecker separately, configure these env vars in its server config:

```bash
WOODPECKER_FORGEJO=true
WOODPECKER_FORGEJO_URL=http://localhost:3000
WOODPECKER_FORGEJO_CLIENT=<oauth2-client-id>
WOODPECKER_FORGEJO_SECRET=<oauth2-client-secret>
```

To create the OAuth2 app on Forgejo:

```bash
# Create OAuth2 application (redirect URI = Woodpecker authorize endpoint)
curl -X POST \
  -H "Authorization: token ${FORGE_TOKEN}" \
  -H "Content-Type: application/json" \
  "http://localhost:3000/api/v1/user/applications/oauth2" \
  -d '{"name":"woodpecker-ci","redirect_uris":["http://localhost:8000/authorize"],"confidential_client":true}'
```

The response contains `client_id` and `client_secret` for `WOODPECKER_FORGEJO_CLIENT` / `WOODPECKER_FORGEJO_SECRET`.

To activate the repo in Woodpecker:

```bash
woodpecker-cli repo add <org>/<repo>
# Or via API:
curl -X POST \
  -H "Authorization: Bearer ${WOODPECKER_TOKEN}" \
  "http://localhost:8000/api/repos" \
  -d '{"forge_remote_id":"<org>/<repo>"}'
```

Woodpecker will now trigger pipelines on pushes to Forgejo and push commit status back. Disinto queries Woodpecker directly for CI status (with a forge API fallback), so pipeline results are visible even if Woodpecker's status push to Forgejo is delayed.

## 6. Prepare the Target Repo

### Required: CI pipeline

The repo needs at least one Woodpecker pipeline. Disinto monitors CI status to decide when a PR is ready for review and when it can merge.

### Required: `CLAUDE.md`

Create a `CLAUDE.md` in the repo root. This is the context document that dev-agent and review-agent read before working. It should cover:

- **What the project is** (one paragraph)
- **Tech stack** (languages, frameworks, DB)
- **How to build/run/test** (`npm install`, `npm test`, etc.)
- **Coding conventions** (import style, naming, linting rules)
- **Project structure** (key directories and what lives where)

The dev-agent reads this file via `claude -p` before implementing any issue. The better this file, the better the output.

### Required: Issue labels

`disinto init` creates these automatically. If setting up manually, create these labels on the forge repo:

| Label | Purpose |
|-------|---------|
| `backlog` | Issues ready to be picked up by dev-agent |
| `in-progress` | Managed by dev-agent (auto-applied, auto-removed) |

Optional but recommended:

| Label | Purpose |
|-------|---------|
| `tech-debt` | Gardener can promote these to `backlog` |
| `blocked` | Dev-agent marks issues with unmet dependencies |
| `formula` | **Not yet functional.** Formula dispatch lives on the unmerged `feat/formula` branch. Dev-agent will skip any issue with this label until that branch is merged. Template files exist in `formulas/` for future use. |

### Required: Branch protection

On Forgejo, set up branch protection for your primary branch:

- **Require pull request reviews**: enabled
- **Required approvals**: 1 (from the review bot account)
- **Restrict push**: only allow merges via PR

This ensures dev-agent can't merge its own PRs — it must wait for review-agent (running as the bot account) to approve.

> **Common pitfall:** Approvals alone are not enough. You must also:
> 1. Add `review-bot` as a **write** collaborator on the repo (Settings → Collaborators)
> 2. Set both `approvals_whitelist_username` **and** `merge_whitelist_usernames` to include `review-bot` in the branch protection rule
>
> Without write access, the bot's approval is counted but the merge API returns HTTP 405.

### Required: Seed the `AGENTS.md` tree

The planner maintains an `AGENTS.md` tree — architecture docs with
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

See `formulas/run-planner.toml` (agents-update step) for the full AGENTS.md conventions.

## 7. Write Good Issues

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

## 8. Install Cron

```bash
crontab -e
```

### Single project

Add (adjust paths):

```cron
FACTORY_ROOT=/home/you/disinto

# Supervisor — health checks, auto-healing (every 10 min)
0,10,20,30,40,50 * * * * $FACTORY_ROOT/supervisor/supervisor-poll.sh

# Review agent — find unreviewed PRs (every 10 min, offset +3)
3,13,23,33,43,53 * * * * $FACTORY_ROOT/review/review-poll.sh $FACTORY_ROOT/projects/myproject.toml

# Dev agent — find ready issues, implement (every 10 min, offset +6)
6,16,26,36,46,56 * * * * $FACTORY_ROOT/dev/dev-poll.sh $FACTORY_ROOT/projects/myproject.toml

# Gardener — backlog grooming (daily)
15 8 * * *                $FACTORY_ROOT/gardener/gardener-poll.sh

# Planner — AGENTS.md maintenance + gap analysis (weekly)
0 9 * * 1                 $FACTORY_ROOT/planner/planner-poll.sh
```

`review-poll.sh`, `dev-poll.sh`, and `gardener-poll.sh` all take a project TOML file as their first argument.

### Multiple projects

Stagger each project's polls so they don't overlap. With the example below, cross-project gaps are 2 minutes:

```cron
FACTORY_ROOT=/home/you/disinto

# Supervisor (shared)
0,10,20,30,40,50 * * * * $FACTORY_ROOT/supervisor/supervisor-poll.sh

# Project A — review +3, dev +6
3,13,23,33,43,53 * * * * $FACTORY_ROOT/review/review-poll.sh $FACTORY_ROOT/projects/project-a.toml
6,16,26,36,46,56 * * * * $FACTORY_ROOT/dev/dev-poll.sh     $FACTORY_ROOT/projects/project-a.toml

# Project B — review +8, dev +1  (2-min gap from project A)
8,18,28,38,48,58 * * * * $FACTORY_ROOT/review/review-poll.sh $FACTORY_ROOT/projects/project-b.toml
1,11,21,31,41,51 * * * * $FACTORY_ROOT/dev/dev-poll.sh     $FACTORY_ROOT/projects/project-b.toml

# Gardener — per-project backlog grooming (daily)
15 8 * * *                $FACTORY_ROOT/gardener/gardener-poll.sh $FACTORY_ROOT/projects/project-a.toml
45 8 * * *                $FACTORY_ROOT/gardener/gardener-poll.sh $FACTORY_ROOT/projects/project-b.toml

# Planner — AGENTS.md maintenance + gap analysis (weekly)
0 9 * * 1                 $FACTORY_ROOT/planner/planner-poll.sh
```

The staggered offsets prevent agents from competing for resources. Each project gets its own lock file (`/tmp/dev-agent-{name}.lock`) derived from the `name` field in its TOML, so concurrent runs across projects are safe.

## 9. Verify

```bash
# Should complete with "all clear" (no problems to fix)
bash supervisor/supervisor-poll.sh

# Should list backlog issues (or "no backlog issues")
bash dev/dev-poll.sh

# Should find no unreviewed PRs (or review one if exists)
bash review/review-poll.sh
```

Check logs after a few cycles:

```bash
tail -30 supervisor/supervisor.log
tail -30 dev/dev-agent.log
tail -30 review/review.log
```

## 10. Optional: Matrix Notifications

If you want real-time notifications and human-in-the-loop escalation:

1. Set `MATRIX_*` vars in `.env`
2. Install the listener as a systemd service:
   ```bash
   sudo cp lib/matrix_listener.service /etc/systemd/system/
   sudo systemctl enable --now matrix_listener
   ```
3. The supervisor and gardener will post status updates and escalation threads to the configured room. Reply in-thread to answer escalations.

### Per-project Matrix setup

Each project can post to its own Matrix room. For each project:

1. **Create a Matrix room** and note its room ID (e.g. `!abc123:matrix.example.org`)
2. **Create a bot user** (or reuse one) and join it to the room
3. **Add the token** to `.env` using a project-prefixed name:
   ```bash
   PROJECTNAME_MATRIX_TOKEN=syt_xxxxx
   ```
4. **Configure the TOML** with a `[matrix]` section:
   ```toml
   [matrix]
   room_id   = "!abc123:matrix.example.org"
   bot_user  = "@projectname-bot:matrix.example.org"
   token_env = "PROJECTNAME_MATRIX_TOKEN"
   ```

The `token_env` field points to the environment variable name, not the token value itself, so you can have multiple bots with separate credentials in a single `.env`.

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
  supervisor-poll monitors health, kills stale processes, manages resources
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
| Memory issues | Supervisor auto-heals at <500 MB free. Check `supervisor/supervisor.log` for P0 alerts. |
| Works on one box but not another | Diff configs first (`~/.claude/settings.json`, `.env`, crontab, branch protection). Write code never — config mismatches are the #1 cause of cross-box failures. |

### Multi-project common blockers

| Symptom | Cause | Fix |
|---------|-------|-----|
| Dev-agent for project B never starts | Shared lock file path | Each TOML `name` field must be unique — lock is `/tmp/dev-agent-{name}.lock` |
| Review-poll skips all PRs | CI gate with no CI configured | Set `woodpecker_repo_id = 0` in the TOML `[ci]` section to bypass the CI check |
| Approved PRs never merge (HTTP 405) | `review-bot` not in merge/approvals whitelist | Add as write collaborator; set both `approvals_whitelist_username` and `merge_whitelist_usernames` in branch protection |
| Dev-agent churns through issues without waiting for open PRs to land | No single-threaded enforcement | `WAITING_PRS` check in dev-poll holds new work — verify TOML `name` is consistent across invocations |
| Label ping-pong (issue reopened then immediately re-closed) | `already_done` handler doesn't close issue | Review dev-agent log; `already_done` status should auto-close the issue |

## Action Runner — disinto (harb-staging)

Added 2026-03-19. Polls disinto repo for `action`-labeled issues.

```
*/5 * * * * cd /home/debian/dark-factory && bash action/action-poll.sh projects/disinto.toml >> /tmp/action-disinto-cron.log 2>&1
```

Runs locally on harb-staging — same box where Caddy/site live. For formulas that need local resources (publish-site, etc).

### Fix applied: action-agent.sh needs +x
The script wasn't executable after git clone. Run:
```bash
chmod +x action/action-agent.sh action/action-poll.sh
```
