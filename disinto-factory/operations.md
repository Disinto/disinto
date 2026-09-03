# Ongoing operations

The production factory (disinto-nomad-box) runs the **Nomad+Vault backend**
(see `setup.md` for how it gets there). Nomad commands are listed first in
each section; the legacy docker-compose equivalents follow, marked **legacy**.

### Check factory status

```bash
# Nomad: all jobs and their allocations
nomad job status

# Nomad: one job in detail (alloc IDs, node, health)
nomad job status agents
nomad job inspect agents -json | jq '.Allocations[] | {ID, ClientStatus, DesiredStatus}'

# Compose (legacy):
# docker ps --format "table {{.Names}}\t{{.Status}}"
```

```bash
source .env

# Issues
curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/issues?state=open" \
  -H "Authorization: token $FORGE_TOKEN" \
  | jq -r '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title)"'

# PRs
curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/pulls?state=open" \
  -H "Authorization: token $FORGE_TOKEN" \
  | jq -r '.[] | "PR #\(.number) [\(.head.ref)] \(.title)"'

# Agent logs
# Nomad: agent logs live on the host under the agent-data volume
tail -20 /srv/disinto/agent-data/logs/dev/dev-agent.log
# or via the allocation:
# nomad alloc logs <agents-allocation-id>

# Compose (legacy):
# docker exec disinto-agents-1 tail -20 /home/agent/data/logs/dev/dev-agent.log
```

### Check agent roles

```bash
# Nomad + compose alike — which roles are enabled/disabled:
bin/disinto role status
```

### Check CI

```bash
source .env
WP_CSRF=$(curl -sf -b "user_sess=$WOODPECKER_TOKEN" http://localhost:8000/web-config.js \
  | sed -n 's/.*WOODPECKER_CSRF = "\([^"]*\)".*/\1/p')
curl -sf -b "user_sess=$WOODPECKER_TOKEN" -H "X-CSRF-Token: $WP_CSRF" \
  "http://localhost:8000/api/repos/1/pipelines?page=1&per_page=5" \
  | jq '.[] | {number, status, event}'
```

### Check one service's log

```bash
# Nomad: tail a single task's stdout via its allocation
nomad alloc logs <allocation-id>

# Nomad: restart a misbehaving job (allocs come back fresh)
nomad job restart agents

# Compose (legacy):
# docker logs --tail 100 disinto-agents-1
```

### Unstick a blocked issue

When a dev-agent run fails (CI timeout, implementation error), the issue gets labeled `blocked`:

**Nomad:**
1. Close stale PR and delete the branch
2. Restart the agent job so the pollers rescan clean
   `nomad job restart agents`
3. Relabel the issue to `backlog`
4. Update agent repo (host-side `project-repos` volume):
   `git -C /srv/disinto/project-repos/<name> fetch origin && git -C /srv/disinto/project-repos/<name> reset --hard origin/main`

**Compose (legacy):**
1. Close stale PR and delete the branch
2. `docker exec disinto-agents-1 rm -f /tmp/dev-agent-*.json /tmp/dev-agent-*.lock`
3. Relabel the issue to `backlog`
4. Update agent repo: `docker exec -u agent disinto-agents-1 bash -c "cd /home/agent/repos/<name> && git fetch origin && git reset --hard origin/main"`

### Access Forgejo UI

If running in an LXD container with reverse tunnel:
```bash
# From your machine:
ssh -L 3000:localhost:13000 user@jump-host
# Open http://localhost:3000
```

On a **Nomad** box the edge job (Caddy) also reverse-proxies Forgejo at
`http://<box>/forge/` — open that if there is no direct tunnel.

Reset admin password if needed — **compose only** (on the Nomad box, forgejo
admin creds are read from Vault KV via the job's template stanza; rotate the
KV value and `nomad job restart forgejo` instead):
```bash
docker exec disinto-forgejo-1 su -c "forgejo admin user change-password --username disinto-admin --password <new-pw> --must-change-password=false" git
```
