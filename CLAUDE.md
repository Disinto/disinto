# CLAUDE.md — Skill file for disinto

## What is disinto?

Disinto is an autonomous code factory — bash scripts + Claude CLI that automate the full
software development lifecycle: picking up issues, implementing via Claude, creating PRs,
running CI, reviewing, merging, and mirroring to external forges.

Read `VISION.md` for the project philosophy, `AGENTS.md` for architecture, and
`BOOTSTRAP.md` for setup instructions.

## Setting up a new factory instance

### Prerequisites

- An LXD container (Debian 12) with Docker, git, jq, curl, tmux, python3 (>=3.11)
- `claude` CLI installed and authenticated
- SSH key for mirror pushes (added to GitHub/Codeberg)

### First-time setup

1. **Clone the repo** and cd into it:
   ```bash
   git clone https://codeberg.org/johba/disinto.git && cd disinto
   ```

2. **Run init** against the repo you want the factory to develop:
   ```bash
   bin/disinto init https://codeberg.org/org/repo --yes
   ```
   For self-development (factory develops itself):
   ```bash
   bin/disinto init https://codeberg.org/johba/disinto --yes --repo-root $(pwd)
   ```

3. **Verify the stack** came up:
   ```bash
   docker ps --format "table {{.Names}}\t{{.Status}}"
   ```
   Expected: forgejo (Up), woodpecker (healthy), woodpecker-agent (healthy), agents (Up),
   edge (Up), staging (Up).

4. **Check WOODPECKER_TOKEN** was generated:
   ```bash
   grep WOODPECKER_TOKEN .env
   ```
   If empty, see "Known issues" below.

5. **Verify agent cron** is running:
   ```bash
   docker exec -u agent disinto-agents-1 crontab -l -u agent
   ```

6. **Set up mirrors** (optional):
   Edit `projects/<name>.toml`:
   ```toml
   [mirrors]
   github   = "git@github.com:Org/repo.git"
   codeberg = "git@codeberg.org:user/repo.git"
   ```
   Ensure `~/.ssh` is mounted into the agents container and SSH keys are added
   to the remote forges. The compose template includes the mount; just add your
   public key to GitHub/Codeberg.

### Post-init checklist

- [ ] Stack containers all running and healthy
- [ ] `WOODPECKER_TOKEN` in `.env` is non-empty
- [ ] `projects/<name>.toml` exists with correct `repo_root` and `primary_branch`
- [ ] Labels exist on Forgejo repo: backlog, in-progress, blocked, tech-debt, etc.
- [ ] Agent container can reach Forgejo API: `docker exec disinto-agents-1 bash -c "source /home/agent/disinto/.env && curl -sf http://forgejo:3000/api/v1/version"`
- [ ] Agent repo is cloned: `docker exec -u agent disinto-agents-1 ls /home/agent/repos/<name>`
  - If not: `docker exec disinto-agents-1 chown -R agent:agent /home/agent/repos && docker exec -u agent disinto-agents-1 bash -c "source /home/agent/disinto/.env && git clone http://dev-bot:\${FORGE_TOKEN}@forgejo:3000/org/repo.git /home/agent/repos/<name>"`
- [ ] Create backlog issues on Forgejo for the factory to work on

## Checking on the factory

### Agent status

```bash
# Are agents running?
docker exec disinto-agents-1 bash -c "
  for f in /proc/[0-9]*/cmdline; do
    cmd=\$(tr '\0' ' ' < \$f 2>/dev/null)
    echo \$cmd | grep -qi claude && echo PID \$(echo \$f | cut -d/ -f3): running
  done
"

# Latest dev-agent activity
docker exec disinto-agents-1 tail -20 /home/agent/data/logs/dev/dev-agent.log

# Latest poll activity
docker exec disinto-agents-1 tail -20 /home/agent/data/logs/dev/dev-agent-<project>.log
```

### Issue and PR status

```bash
source .env
# Open issues
curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/issues?state=open" \
  -H "Authorization: token $FORGE_TOKEN" | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"'

# Open PRs
curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/pulls?state=open" \
  -H "Authorization: token $FORGE_TOKEN" | jq -r '.[] | "PR #\(.number) [\(.head.ref)] \(.title)"'
```

### CI status

```bash
source .env
# Check pipelines (requires session cookie + CSRF for WP v3 API)
WP_CSRF=$(curl -sf -b "user_sess=$WOODPECKER_TOKEN" http://localhost:8000/web-config.js \
  | sed -n 's/.*WOODPECKER_CSRF = "\([^"]*\)".*/\1/p')
curl -sf -b "user_sess=$WOODPECKER_TOKEN" -H "X-CSRF-Token: $WP_CSRF" \
  "http://localhost:8000/api/repos/1/pipelines?page=1&per_page=5" \
  | jq '.[] | {number, status, event}'
```

### Unsticking a blocked issue

When a dev-agent run fails (CI timeout, implementation error), the issue gets labeled
`blocked`. To retry:

```bash
source .env
# 1. Close stale PR if any
curl -sf -X PATCH "http://localhost:3000/api/v1/repos/<org>/<repo>/pulls/<N>" \
  -H "Authorization: token $FORGE_TOKEN" -H "Content-Type: application/json" \
  -d '{"state":"closed"}'

# 2. Delete stale branch
curl -sf -X DELETE "http://localhost:3000/api/v1/repos/<org>/<repo>/branches/fix/issue-<N>" \
  -H "Authorization: token $FORGE_TOKEN"

# 3. Remove locks
docker exec disinto-agents-1 rm -f /tmp/dev-agent-*.json /tmp/dev-agent-*.lock

# 4. Relabel issue to backlog
BACKLOG_ID=$(curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/labels" \
  -H "Authorization: token $FORGE_TOKEN" | jq -r '.[] | select(.name=="backlog") | .id')
curl -sf -X PUT "http://localhost:3000/api/v1/repos/<org>/<repo>/issues/<N>/labels" \
  -H "Authorization: token $FORGE_TOKEN" -H "Content-Type: application/json" \
  -d "{\"labels\":[$BACKLOG_ID]}"

# 5. Update agent repo to latest main
docker exec -u agent disinto-agents-1 bash -c \
  "cd /home/agent/repos/<name> && git fetch origin && git reset --hard origin/main"
```

The next cron cycle (every 5 minutes) will pick it up.

### Triggering a poll manually

```bash
docker exec -u agent disinto-agents-1 bash -c \
  "cd /home/agent/disinto && bash dev/dev-poll.sh projects/<name>.toml"
```

## Filing issues

The factory picks up issues labeled `backlog`. The dev-agent:
1. Claims the issue (labels it `in-progress`)
2. Creates a worktree on branch `fix/issue-<N>`
3. Runs Claude to implement the fix
4. Pushes, creates a PR, waits for CI
5. Requests review from review-bot
6. Merges on approval, pushes to mirrors

Issue body should contain enough context for Claude to implement it. Include:
- What's wrong or what needs to change
- Which files are affected
- Any design constraints
- Dependency references: `Depends-on: #N` (dev-agent checks these before starting)

Use labels:
- `backlog` — ready for the dev-agent to pick up
- `blocked` — not ready (missing dependency, needs investigation)
- `in-progress` — claimed by dev-agent (set automatically)
- No label — parked, not for the factory to touch

## Reverse tunnel access (for browser UI)

If running in an LXD container with a reverse SSH tunnel to a jump host:

```bash
# On the LXD container, add to /etc/systemd/system/reverse-tunnel.service:
#   -R 127.0.0.1:13000:localhost:3000  (Forgejo)
#   -R 127.0.0.1:18000:localhost:8000  (Woodpecker)

# From your machine:
ssh -L 3000:localhost:13000 user@jump-host
# Then open http://localhost:3000 in your browser
```

Forgejo admin login: `disinto-admin` / set during init (or reset with
`docker exec disinto-forgejo-1 su -c "forgejo admin user change-password --username disinto-admin --password <pw> --must-change-password=false" git`).

## Known issues & workarounds

### WP CI agent needs host networking in LXD

Docker bridge networking inside LXD breaks gRPC/HTTP2. The compose template uses
`network_mode: host` + `privileged: true` for the WP agent, connecting via
`localhost:9000`. This is baked into the template and works on regular VMs too.

### CI step containers need Docker network

The WP agent spawns CI containers that need to reach Forgejo for git clone.
`WOODPECKER_BACKEND_DOCKER_NETWORK: disinto_disinto-net` is set in the compose
template to put CI containers on the compose network.

### Forgejo webhook allowlist

Forgejo blocks outgoing webhooks by default. The compose template sets
`FORGEJO__webhook__ALLOWED_HOST_LIST: "private"` to allow delivery to
Docker-internal hosts.

### OAuth2 token generation during init

The init script drives a Forgejo OAuth2 flow to generate a Woodpecker token.
This requires rewriting URL-encoded Docker-internal hostnames and submitting
all Forgejo grant form fields. If token generation fails, check Forgejo logs
for "Unregistered Redirect URI" errors.

### Woodpecker UI not accessible via tunnel

The WP OAuth login redirects use Docker-internal hostnames that browsers can't
resolve. Use the Forgejo UI instead — CI results appear as commit statuses on PRs.

### PROJECT_REPO_ROOT inside agents container

The agents container needs `PROJECT_REPO_ROOT` set in its environment to
`/home/agent/repos/<name>` (not the host path from the TOML). The compose
template includes this. If the agent fails with "cd: no such file or directory",
check this env var.

## Code conventions

See `AGENTS.md` for per-file architecture docs and coding conventions.
Key principles:
- Bash for checks, AI for judgment
- Zero LLM tokens when idle (cron checks are pure bash)
- Fire-and-forget mirror pushes (never block the pipeline)
- Issues are the unit of work; PRs are the delivery mechanism
