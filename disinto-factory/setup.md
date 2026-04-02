# First-time setup

Walk the user through these steps interactively. Ask questions where marked with [ASK].

### 1. Environment

[ASK] Where will the factory run? Options:
- **LXD container** (recommended for isolation) — need Debian 12, Docker, nesting enabled
- **Bare VM or server** — need Debian/Ubuntu with Docker
- **Existing container** — check prerequisites

Verify prerequisites:
```bash
docker --version && git --version && jq --version && curl --version && tmux -V && python3 --version && claude --version
```

Any missing tool — help the user install it before continuing.

### 2. Clone disinto and choose a target project

Clone the disinto factory itself:
```bash
git clone https://codeberg.org/johba/disinto.git && cd disinto
```

[ASK] What repository should the factory develop? Provide the **remote repository URL** in one of these formats:
- Full URL: `https://github.com/johba/harb.git` or `https://codeberg.org/johba/harb.git`
- Short slug: `johba/harb` (uses local Forgejo as the primary remote)

The factory will clone from the remote URL (if provided) or from your local Forgejo, then mirror to the remote.

Then initialize the factory for that project:
```bash
bin/disinto init johba/harb --yes
# or with full URL:
bin/disinto init https://github.com/johba/harb.git --yes
```

The `init` command will:
- Create all bot users (dev-bot, review-bot, etc.) on the local Forgejo
- Generate and save `WOODPECKER_TOKEN`
- Start the stack containers
- Clone the target repo into the agent workspace

> **Note:** The `--repo-root` flag is optional and only needed if you want to customize
> where the cloned repo lives. By default, it goes under `/home/agent/repos/<name>`.

### 3. Post-init verification

Run this checklist — fix any failures before proceeding:

```bash
# Stack healthy?
docker ps --format "table {{.Names}}\t{{.Status}}"
# Expected: forgejo, woodpecker (healthy), woodpecker-agent (healthy), agents, edge, staging

# Token generated?
grep WOODPECKER_TOKEN .env | grep -v "^$" && echo "OK" || echo "MISSING — see references/troubleshooting.md"

# Agent cron active?
docker exec -u agent disinto-agents-1 crontab -l -u agent

# Agent can reach Forgejo?
docker exec disinto-agents-1 bash -c "source /home/agent/disinto/.env && curl -sf http://forgejo:3000/api/v1/version | jq .version"

# Agent repo cloned?
docker exec -u agent disinto-agents-1 ls /home/agent/repos/
```

If the agent repo is missing, clone it:
```bash
docker exec disinto-agents-1 chown -R agent:agent /home/agent/repos
docker exec -u agent disinto-agents-1 bash -c "source /home/agent/disinto/.env && git clone http://dev-bot:\${FORGE_TOKEN}@forgejo:3000/<org>/<repo>.git /home/agent/repos/<name>"
```

### 4. Create the project configuration file

The factory uses a TOML file to configure how it manages your project. Create
`projects/<name>.toml` based on the template format:

```toml
# projects/harb.toml

name            = "harb"
repo            = "johba/harb"
forge_url       = "http://localhost:3000"
repo_root       = "/home/agent/repos/harb"
primary_branch  = "master"

[ci]
woodpecker_repo_id = 0
stale_minutes      = 60

[services]
containers = ["ponder"]

[monitoring]
check_prs            = true
check_dev_agent      = true
check_pipeline_stall = true

# [mirrors]
# github   = "git@github.com:johba/harb.git"
# codeberg = "git@codeberg.org:johba/harb.git"
```

**Key fields:**
- `name`: Project identifier (used for file names, logs, etc.)
- `repo`: The source repo in `owner/name` format
- `forge_url`: URL of your local Forgejo instance
- `repo_root`: Where the agent clones the repo
- `primary_branch`: Default branch name (e.g., `main` or `master`)
- `woodpecker_repo_id`: Set to `0` initially; auto-populated on first CI run
- `containers`: List of Docker containers the factory should manage
- `mirrors`: Optional external forge URLs for backup/sync

### 5. Mirrors (optional)

[ASK] Should the factory mirror to external forges? If yes, which?
- GitHub: need repo URL and SSH key added to GitHub account
- Codeberg: need repo URL and SSH key added to Codeberg account

Show the user their public key:
```bash
cat ~/.ssh/id_ed25519.pub
```

Test SSH access:
```bash
ssh -T git@github.com 2>&1; ssh -T git@codeberg.org 2>&1
```

If SSH host keys are missing: `ssh-keyscan github.com codeberg.org >> ~/.ssh/known_hosts 2>/dev/null`

Edit `projects/<name>.toml` to uncomment and configure mirrors:
```toml
[mirrors]
github   = "git@github.com:Org/repo.git"
codeberg = "git@codeberg.org:user/repo.git"
```

Test with a manual push:
```bash
source .env && source lib/env.sh && export PROJECT_TOML=projects/<name>.toml && source lib/load-project.sh && source lib/mirrors.sh && mirror_push
```

### 6. Seed the backlog

[ASK] What should the factory work on first? Brainstorm with the user.

Help them create issues on the local Forgejo. Each issue needs:
- A clear title prefixed with `fix:`, `feat:`, or `chore:`
- A body describing what to change, which files, and any constraints
- The `backlog` label (so the dev-agent picks it up)

```bash
source .env
BACKLOG_ID=$(curl -sf "http://localhost:3000/api/v1/repos/<org>/<repo>/labels" \
  -H "Authorization: token $FORGE_TOKEN" | jq -r '.[] | select(.name=="backlog") | .id')

curl -sf -X POST "http://localhost:3000/api/v1/repos/<org>/<repo>/issues" \
  -H "Authorization: token $FORGE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\": \"<title>\", \"body\": \"<body>\", \"labels\": [$BACKLOG_ID]}"
```

For issues with dependencies, add `Depends-on: #N` in the body — the dev-agent checks
these before starting.

Use labels:
- `backlog` — ready for the dev-agent
- `blocked` — parked, not for the factory
- No label — tracked but not for autonomous work

### 7. Watch it work

The dev-agent polls every 5 minutes. Trigger manually to see it immediately:
```bash
source .env
export PROJECT_TOML=projects/<name>.toml
docker exec -u agent disinto-agents-1 bash -c "cd /home/agent/disinto && bash dev/dev-poll.sh projects/<name>.toml"
```

Then monitor:
```bash
# Watch the agent work
docker exec disinto-agents-1 tail -f /home/agent/data/logs/dev/dev-agent.log

# Check for Claude running
docker exec disinto-agents-1 bash -c "for f in /proc/[0-9]*/cmdline; do cmd=\$(tr '\0' ' ' < \$f 2>/dev/null); echo \$cmd | grep -q 'claude.*-p' && echo 'Claude is running'; done"
```
