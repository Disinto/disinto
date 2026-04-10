# Updating the Disinto Factory

How to update the disinto factory code on a deployment box (e.g. harb-dev-box)
after a new version lands on the upstream Forgejo.

## Prerequisites

- SSH access to the deployment box
- The upstream remote (`devbox`) pointing to the disinto-dev-box Forgejo

## Step 1: Pull the latest code

```bash
cd ~/disinto
git fetch devbox main
git log --oneline devbox/main -5   # review what changed
git stash                           # save any local fixes
git merge devbox/main
```

## Note: docker-compose.yml is generator-only

The `docker-compose.yml` file is now generated exclusively by `bin/disinto init`.
The tracked file has been removed. If you have a local `docker-compose.yml` from
before this change, it is now "yours" and won't be touched by future updates.
To pick up generator improvements, delete the existing file and run `bin/disinto init`.

## Step 2: Preserve local config

These files are not in git but are needed at runtime. Back them up before
any compose regeneration:

```bash
cp .env .env.backup
cp projects/harb.toml projects/harb.toml.backup
cp docker-compose.override.yml docker-compose.override.yml.backup 2>/dev/null
```

## Step 3: Regenerate docker-compose.yml

If `generate_compose()` changed or you need a fresh compose file:

```bash
rm docker-compose.yml
source .env
bin/disinto init https://codeberg.org/johba/harb --branch master --yes
```

This will regenerate the compose but may fail partway through (token collisions,
existing users). The compose file is written early — check it exists even if
init errors out.

### Known post-regeneration fixes (until #429 lands)

Most generator issues have been fixed. The following items no longer apply:

- **AppArmor (#492)** — Fixed: all services now have `apparmor=unconfined`
- **Forgejo image tag (#493)** — Fixed: generator uses `forgejo:11.0`
- **Agent credential mounts (#495)** — Fixed: `.claude`, `.claude.json`, `.ssh`, and `project-repos` volumes are auto-generated
- **Repo path (#494)** — Not applicable: `projects/*.toml` files are gitignored and preserved

If you need to add custom volumes, edit the generated `docker-compose.yml` directly.
It will not be overwritten by future `init` runs (the generator skips existing files).

## Step 4: Rebuild and restart

```bash
# Rebuild agents image (code is baked in via COPY)
docker compose build agents

# Restart all disinto services
docker compose up -d

# If edge fails to build (caddy:alpine has no apt-get), skip it:
docker compose up -d forgejo woodpecker woodpecker-agent agents staging
```

## Step 5: Verify

```bash
# All containers running?
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep disinto

# Forgejo responding?
curl -sf -o /dev/null -w 'HTTP %{http_code}' http://localhost:3000/

# Claude auth works?
docker exec -u agent disinto-agents bash -c 'claude -p "say ok" 2>&1'

# Agent polling loop running?
docker exec disinto-agents pgrep -f entrypoint.sh
# If no process: check that entrypoint.sh is the container CMD and projects TOML is mounted.

# Agent repo cloned?
docker exec disinto-agents ls /home/agent/repos/harb/.git && echo ok
# If missing:
docker exec disinto-agents chown -R agent:agent /home/agent/repos
source .env
docker exec -u agent disinto-agents bash -c \
  "git clone http://dev-bot:${FORGE_TOKEN}@forgejo:3000/johba/harb.git /home/agent/repos/harb"

# Git safe.directory (needed after volume recreation)
docker exec -u agent disinto-agents git config --global --add safe.directory /home/agent/repos/harb
```

## Step 6: Verify harb stack coexistence

```bash
# Harb stack still running?
cd ~/harb && docker compose ps --format 'table {{.Name}}\t{{.Status}}'

# No port conflicts?
# Forgejo: 3000, Woodpecker: 8000, harb caddy: 8081, umami: 3001
ss -tlnp | grep -E '3000|3001|8000|8081'
```

## Step 7: Docker disk hygiene

The reproduce image is ~1.3GB. Dangling images accumulate fast.

```bash
# Check disk
df -h /

# Prune dangling images (safe — only removes unused)
docker image prune -f

# Nuclear option (removes ALL unused images, volumes, networks):
docker system prune -af
# WARNING: this removes cached layers, requiring full rebuilds
```

## Troubleshooting

### Forgejo at 170%+ CPU, not responding
AppArmor issue. Add `security_opt: [apparmor=unconfined]` and recreate:
```bash
docker compose up -d forgejo
```

### "Not logged in" / OAuth expired
Re-auth on the host:
```bash
claude auth login
```
Credentials are bind-mounted into containers automatically.
Multiple containers sharing OAuth can cause frequent expiry — consider
using `ANTHROPIC_API_KEY` in `.env` instead.

### Agent loop not running after restart
The entrypoint reads `projects/*.toml` to determine which agents to run.
If the TOML isn't mounted or the disinto directory is read-only,
the polling loop won't start agents. Check:
```bash
docker exec disinto-agents ls /home/agent/disinto/projects/harb.toml
docker logs disinto-agents --tail 20  # look for "Entering polling loop"
```

### "fatal: not a git repository"
After image rebuilds, the baked-in `/home/agent/disinto` has no `.git`.
This breaks review-pr.sh (#408). Workaround:
```bash
docker exec -u agent disinto-agents git config --global --add safe.directory '*'
```

### Dev-agent stuck on closed issue
The dev-poll latches onto in-progress issues. If the issue was closed
externally, the agent skips it every cycle but never moves on. Check:
```bash
docker exec disinto-agents tail -5 /home/agent/data/logs/dev/dev-agent.log
```
Fix: clean the worktree and let it re-scan:
```bash
docker exec disinto-agents rm -rf /tmp/harb-worktree-*
```
