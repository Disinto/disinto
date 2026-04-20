# Edge Control Plane

SSH-forced-command control plane for managing reverse tunnels to edge hosts.

## Overview

This control plane runs on the public edge host (Debian DO box) and provides:

- **Self-service tunnel registration**: Projects run `disinto edge register` to get an assigned port and FQDN
- **SSH forced commands**: Uses `restrict,command="..."` authorized_keys entries — no new HTTP daemon
- **Hot-patched Caddy routing**: `<project>.disinto.ai` → `127.0.0.1:<port>` via Caddy admin API
- **Port allocator**: Manages ports in `20000-29999` range with flock-based concurrency control

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Edge Host (Debian DO)                              │
│                                                                              │
│  ┌──────────────────┐    ┌───────────────────────────────────────────────┐  │
│  │  disinto-register│    │  /var/lib/disinto/                            │  │
│  │  (authorized_keys│    │  ├── registry.json (source of truth)          │  │
│  │   forced cmd)    │    │  ├── registry.lock (flock)                    │  │
│  │                  │    │  └── allowlist.json (admin-approved names)    │  │
│  │                  │    │  └── authorized_keys (rebuildable)            │  │
│  └────────┬─────────┘    └───────────────────────────────────────────────┘  │
│           │                                                                   │
│           ▼                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │  register.sh (forced command handler)                                │     │
│  │  ──────────────────────────────────────────────────────────────────  │     │
│  │  • Parses SSH_ORIGINAL_COMMAND                                       │     │
│  │  • Dispatches to register|deregister|list                            │     │
│  │  • Returns JSON on stdout                                            │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
│           │                                                                   │
│           │ lib/                                                              │
│           ├─ ports.sh    → port allocator (20000-29999)                      │
│           ├─ authorized_keys.sh → rebuild authorized_keys from registry     │
│           └─ caddy.sh    → Caddy admin API (127.0.0.1:2019)                  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │  Caddy (with Gandi DNS plugin)                                       │     │
│  │  ──────────────────────────────────────────────────────────────────  │     │
│  │  • Admin API on 127.0.0.1:2019                                       │     │
│  │  • Wildcard *.disinto.ai cert (DNS-01 via Gandi)                     │     │
│  │  • Site blocks hot-patched via admin API                             │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐     │
│  │  disinto-tunnel (no shell, no password)                              │     │
│  │  ──────────────────────────────────────────────────────────────────  │     │
│  │  • Receives reverse tunnels only                                     │     │
│  │  • authorized_keys: permitlisten="127.0.0.1:<port>"                  │     │
│  └─────────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Installation

### Prerequisites

- Fresh Debian 12 (Bookworm) system
- Root or sudo access
- Domain `disinto.ai` hosted at Gandi with API token

### One-Click Install

```bash
# Download and run installer
curl -sL https://raw.githubusercontent.com/disinto-admin/disinto/fix/issue-621/tools/edge-control/install.sh | bash -s -- --gandi-token YOUR_GANDI_API_TOKEN

# You'll be prompted to paste your admin pubkey for the disinto-register user
```

### What install.sh Does

1. **Creates users**:
   - `disinto-register` — owns registry, runs Caddy admin API calls
   - `disinto-tunnel` — no password, no shell, only receives reverse tunnels

2. **Creates data directory**:
   - `/var/lib/disinto/` with `registry.json`, `registry.lock`, `allowlist.json`
   - Permissions: `root:disinto-register 0750`

3. **Installs Caddy**:
   - Backs up any pre-existing `/etc/caddy/Caddyfile` to `/etc/caddy/Caddyfile.pre-disinto`
   - Download Caddy with Gandi DNS plugin
   - Enable admin API on `127.0.0.1:2019`
   - Configure wildcard cert for `*.disinto.ai` via DNS-01
   - Creates `/etc/caddy/extra.d/` for operator-owned site blocks
   - Emitted Caddyfile ends with `import /etc/caddy/extra.d/*.caddy`

4. **Sets up SSH**:
   - Creates `disinto-register` authorized_keys with forced command
   - Creates `disinto-tunnel` authorized_keys (rebuildable from registry)

5. **Installs control plane scripts**:
   - `/opt/disinto-edge/register.sh` — forced command handler
   - `/opt/disinto-edge/lib/*.sh` — helper libraries

## Operator-Owned Site Blocks

Edge-control owns the top-level `/etc/caddy/Caddyfile` and dynamic `<project>.<DOMAIN_SUFFIX>` routes injected via the Caddy admin API. Operators own everything under `/etc/caddy/extra.d/`.

To serve non-tunnel content (apex domain, www redirect, static sites), drop `.caddy` files into `/etc/caddy/extra.d/`:

```bash
# Example: /etc/caddy/extra.d/landing.caddy
disinto.ai {
  root * /home/debian/disinto-site
  file_server
}

# Example: /etc/caddy/extra.d/www-redirect.caddy
www.disinto.ai {
  redir https://disinto.ai{uri} permanent
}
```

These files survive across `install.sh` re-runs. The `--extra-caddyfile <path>` flag overrides the default import glob (`/etc/caddy/extra.d/*.caddy`) if needed.

## Usage

### Register a Tunnel (from dev box)

```bash
# First-time setup (generates tunnel keypair)
disinto edge register myproject

# Subsequent runs are idempotent
disinto edge register myproject  # returns same port/FQDN
```

Response:
```json
{"port":23456,"fqdn":"myproject.disinto.ai"}
```

These values are written to `.env` as:
```
EDGE_TUNNEL_HOST=edge.disinto.ai
EDGE_TUNNEL_PORT=23456
EDGE_TUNNEL_FQDN=myproject.disinto.ai
```

### Deregister a Tunnel

```bash
disinto edge deregister myproject
```

This:
- Removes the authorized_keys entry for the tunnel
- Removes the Caddy site block
- Frees the port in the registry

### Check Status

```bash
disinto edge status
```

Shows all registered tunnels with their ports and FQDNs.

## Registry Schema

`/var/lib/disinto/registry.json`:

```json
{
  "version": 1,
  "projects": {
    "myproject": {
      "port": 23456,
      "fqdn": "myproject.disinto.ai",
      "pubkey": "ssh-ed25519 AAAAC3Nza... operator@devbox",
      "registered_at": "2026-04-10T14:30:00Z"
    }
  }
}
```

## Allowlist

The allowlist prevents project name squatting by requiring admin approval before a name can be registered. It is **opt-in**: when `allowlist.json` is empty (no project entries), registration works as before. Once the admin adds entries, only approved names are accepted.

### Setup

Edit `/var/lib/disinto/allowlist.json` as root:

```json
{
  "version": 1,
  "allowed": {
    "myproject": {
      "pubkey_fingerprint": "SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    },
    "open-project": {
      "pubkey_fingerprint": ""
    }
  }
}
```

- **With `pubkey_fingerprint`**: Only the specified SSH key can register this project name. The fingerprint is the SHA256 output of `ssh-keygen -lf <keyfile>`.
- **With empty `pubkey_fingerprint`**: Any caller may register this project name (name reservation without key binding).
- **Not listed**: Registration is refused with `{"error":"name not approved"}`.

### Workflow

1. Admin edits `/var/lib/disinto/allowlist.json` (via ops repo PR, or direct `ssh root@edge`).
2. File is `root:root 0644` — `disinto-register` only reads it; `register.sh` never mutates it.
3. Callers run `register` as usual. The allowlist is checked transparently.

### Security

- The allowlist is a **first-come-first-serve defense**: once a name is approved for a key, no one else can claim it.
- It does **not** replace per-operation ownership checks (sibling issue #1094) — it only prevents the initial race.

## Recovery

### After State Loss

If `registry.json` is lost but Caddy config persists:

```bash
# Rebuild from existing Caddy config
ssh disinto-register@edge.disinto.ai '
  /opt/disinto-edge/lib/rebuild-registry-from-caddy.sh
'
```

### Rebuilding authorized_keys

If `authorized_keys` is corrupted:

```bash
ssh disinto-register@edge.disinto.ai '
  /opt/disinto-edge/lib/rebuild-authorized-keys.sh
'
```

### Rotating Admin Key

To rotate the `disinto-register` admin pubkey:

```bash
# On edge host, remove old pubkey from authorized_keys
# Add new pubkey: echo "new-pubkey" >> /home/disinto-register/.ssh/authorized_keys
# Trigger rebuild: /opt/disinto-edge/lib/rebuild-authorized-keys.sh
```

### Adding a Second Edge Host

For high availability, add a second edge host:

1. Run `install.sh` on the second host
2. Configure Caddy to use the same registry (NFS or shared storage)
3. Update `EDGE_HOST` in `.env` to load-balance between hosts
4. Use a reverse proxy (HAProxy, Traefik) in front of both edge hosts

## Security

### What's Protected

- **No new attack surface**: sshd is already the only listener; control plane is a forced command
- **Restricted tunnel user**: `disinto-tunnel` cannot shell in, only receive reverse tunnels
- **Port validation**: Tunnel connections outside allocated ports are refused
- **Forced command**: `disinto-register` can only execute `register.sh`

### Certificate Strategy

- Single wildcard `*.disinto.ai` cert via DNS-01 through Gandi
- Caddy handles automatic renewal
- No per-project cert work needed

### Future Considerations

- Long-term "shop" vision could layer an HTTP API on top
- forward_auth / OAuth is out of scope (handled per-project inside edge container)

## Testing

### Verify Tunnel User Restrictions

```bash
# Should hang (no command given)
ssh -i tunnel_key disinto-tunnel@edge.disinto.ai

# Should fail (port outside allocation)
ssh -R 127.0.0.1:9999:localhost:80 disinto-tunnel@edge.disinto.ai

# Should succeed (port within allocation)
ssh -R 127.0.0.1:23456:localhost:80 disinto-tunnel@edge.disinto.ai
```

### Verify Admin User Restrictions

```bash
# Should fail (not a valid command)
ssh disinto-register@edge.disinto.ai "random command"

# Should succeed (valid command)
ssh disinto-register@edge.disinto.ai "register myproject $(cat ~/.ssh/id_ed25519.pub)"
```

## Files

- `install.sh` — One-shot installer for fresh Debian DO box
- `register.sh` — Forced-command handler (dispatches to `register|deregister|list`)
- `lib/ports.sh` — Port allocator over `20000-29999`, jq-based, flockd
- `lib/authorized_keys.sh` — Deterministic rebuild of `disinto-tunnel` authorized_keys
- `lib/caddy.sh` — POST to Caddy admin API for route mapping
- `/var/lib/disinto/allowlist.json` — Admin-approved project name allowlist (root-owned, read-only by register.sh)

## Dependencies

- `bash` — All scripts are bash
- `jq` — JSON parsing for registry
- `flock` — Concurrency control for registry updates
- `caddy` — Web server with admin API and Gandi DNS plugin
- `ssh` — OpenSSH for forced commands and reverse tunnels
