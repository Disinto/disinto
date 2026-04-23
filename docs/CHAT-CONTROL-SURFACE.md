# Chat-Claude Factory Control Surface

Scope: what the chat subprocess inside the edge container can do on behalf of
the signed-in operator (currently `disinto-admin`). Design issue: **#650**
(deliberate override of the sandbox posture stated in #326 while
disinto-admin is the sole user and the edge is network-scoped to nomad-box).

## Threat model in one paragraph

A compromised chat session = full factory operator shell. The only gate is
Forgejo OAuth + the single-user allowlist in `docker/chat/server.py`. Every
mitigation below (allow-list, deny-list, limited Nomad ACL scope) raises the
bar against bugs and accidents; none of them defend against an authenticated
bad actor holding the operator's OAuth cookie.

## Files that define the surface

| File | What it configures |
|---|---|
| `docker/edge/chat-settings.json` | Claude Code `.claude/settings.json` — `permissions.defaultMode = acceptEdits`, Bash allow-list, Bash deny-list. |
| `docker/edge/chat-mcp.json` | `.mcp.json` — `forge-api` (HTTP) + `disinto-cli` (stdio) MCP servers. |
| `docker/edge/disinto-mcp` | stdio MCP wrapper around `/opt/disinto/bin/disinto`. |
| `docker/edge/Dockerfile` | Installs `nomad` CLI, `disinto-mcp`, and the two config templates. |
| `docker/edge/entrypoint-edge.sh` | Copies templates into `$CHAT_WORKSPACE_DIR`; loads `FACTORY_FORGE_PAT` / `NOMAD_TOKEN` from `/secrets/*` file mounts. |
| `nomad/jobs/edge.hcl` (caddy task) | Mounts `docker.sock` rw; renders Vault secrets to `/secrets/forge-pat` + `/secrets/nomad-token`; sets `CHAT_WORKSPACE_DIR=/opt/disinto`. |
| `vault/policies/service-edge-chat.hcl` | Reads `kv/disinto/chat`. |
| `vault/roles.yaml` | Binds the `service-edge-chat` role to `job_id: edge`. |
| `nomad/acl-policies/chat-ops.hcl` | Nomad ACL scope for the operator token. |

## Setup steps (one-shot, after cluster-up)

1. **Seed Vault KV** with the two secrets:
   ```
   vault kv put kv/disinto/chat \
     forge_pat=<admin PAT with repo:rw, issues:rw, PRs:rw> \
     nomad_token=<secret-id from step 2>
   ```

2. **Install the Nomad ACL policy** and mint the token whose secret goes in
   Vault in step 1:
   ```
   nomad acl policy apply -description "chat-Claude operator scope" \
     chat-ops nomad/acl-policies/chat-ops.hcl
   nomad acl token create -name=chat-ops -policy=chat-ops -type=client
   ```

3. **Apply Vault policy + role**:
   ```
   vault policy write service-edge-chat vault/policies/service-edge-chat.hcl
   tools/vault-apply-roles.sh   # picks up the new row in vault/roles.yaml
   ```

4. **Rebuild + redeploy edge**:
   ```
   docker build -t disinto/edge:local -f docker/edge/Dockerfile .
   nomad job run nomad/jobs/edge.hcl
   ```

## Permission envelope

- `defaultMode` stays `acceptEdits`. Never `bypassPermissions` — the issue is
  explicit that the blunt "allow everything" escape hatch is too much.
- **Allow** (excerpt — see `chat-settings.json` for the full list):
  `nomad job *`, `nomad alloc *`, `docker ps|logs|inspect|restart|stop|...`,
  `disinto *`, `git *`, `curl https://self.disinto.ai/forge/api/v1/*`.
- **Deny**: `docker volume rm|prune`, `docker system prune`, `docker rm|rmi`,
  `nomad system gc`, `nomad acl *`, `rm -rf /*`, anything touching
  `/var/run/docker.sock` directly, `sudo`.

Deny wins over allow in Claude Code's permission model — so the acceptance
criterion "drop all docker volumes → denied" is enforced even when a user
writes a crafty pipeline that happens to include an allow-list prefix.

## Acceptance criteria (#650)

The following prompts work end-to-end from the chat UI:

- "list nomad jobs" → `nomad job status` via Bash allow-list + `NOMAD_TOKEN`.
- "what's the last CI status on main?" → `forge-api` MCP (or curl).
- "create a backlog issue titled 'foo'" → `forge-api` MCP POST.
- "restart the edge allocation" → `nomad alloc restart <id>` or `docker restart`.
- "drop all docker volumes" → denied by `permissions.deny`.

## Out of scope (revisit later)

- Multi-operator rate limiting / per-user scratch dirs (when a second user lands).
- Voice-layer `think` tool — `#831` will reuse this surface via a handoff.
- Chat-UI-side confirmation step for destructive ops — follow-up.
