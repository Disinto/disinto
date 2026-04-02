# Ongoing operations

### Check factory status

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
docker exec disinto-agents-1 tail -20 /home/agent/data/logs/dev/dev-agent.log
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

### Unstick a blocked issue

When a dev-agent run fails (CI timeout, implementation error), the issue gets labeled `blocked`:

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

Reset admin password if needed:
```bash
docker exec disinto-forgejo-1 su -c "forgejo admin user change-password --username disinto-admin --password <new-pw> --must-change-password=false" git
```
