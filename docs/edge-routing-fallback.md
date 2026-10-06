# Edge Routing Fallback: Per-Project Subdomains

> **Status:** Contingency plan. Only implement if subpath routing (#704 / #708)
> proves unworkable. Tunnel registration (`tools/edge-control/register.sh`)
> and the compose generator (`lib/generators.sh`) already have an
> `EDGE_ROUTING_MODE=subdomain` path (default `subpath`). The live edge is
> `nomad/jobs/edge.hcl`, which does not. A production pivot still changes
> that job. Setting the compose env vars and regenerating `docker/Caddyfile`
> does not pivot the factory that is running.

## Context

The primary approach routes services under subpaths of `<project>.disinto.ai`:

| Service    | Primary (subpath)                          |
|------------|--------------------------------------------|
| Forgejo    | `<project>.disinto.ai/forge/`              |
| Woodpecker | `<project>.disinto.ai/ci/`                 |
| Staging    | `<project>.disinto.ai/staging/`            |

The fallback uses per-service subdomains instead:

| Service    | Fallback (subdomain)                       |
|------------|--------------------------------------------|
| Forgejo    | `forge.<project>.disinto.ai/`              |
| Woodpecker | `ci.<project>.disinto.ai/`                 |
| Staging    | `<project>.disinto.ai/`  (root)            |

`*.disinto.ai` matches one label only (`<project>.disinto.ai`). It does not
cover a sub-subdomain such as `forge.<project>.disinto.ai`. Those names need
a second wildcard (`*.*.disinto.ai`) or explicit DNS records per project, and
a certificate that includes them. Both are straightforward with the existing
Gandi DNS-01 setup. See DNS below.

## Pivot Decision Criteria

**Pivot if:**

- Forgejo `ROOT_URL` under a subpath (`/forge/`) causes redirect loops that
  cannot be fixed with `X-Forwarded-Prefix` or Caddy `uri strip_prefix`.
- Woodpecker's `WOODPECKER_HOST` does not honour subpath prefixes, causing
  OAuth callback mismatches that persist after adjusting redirect URIs.

**Do NOT pivot if:**

- Forgejo login redirects to `/` instead of `/forge/` — fixable with Caddy
  `handle_path` + `uri prefix` rewrite.
- Woodpecker UI assets 404 under `/ci/` — fixable with asset prefix config
  (`WOODPECKER_ROOT_PATH`).
- A single OAuth app needs a second redirect URI — Forgejo supports multiple
  `redirect_uris` in the same app.

## Fallback Topology

### Caddyfile

Two Caddyfiles exist. Only the Nomad one is the live edge.

**Compose (not production).** `lib/generators.sh:_generate_caddyfile_impl`
(around line 825) already branches on `EDGE_ROUTING_MODE`. In `subdomain`
mode it calls `_generate_caddyfile_subdomain` (around line 881), which writes
three host blocks. Do not hand-roll a second compose generator. Those blocks
use Caddy env placeholders and Docker DNS upstreams (`staging:80`,
`forgejo:3000`, `woodpecker:8000`):

```caddy
# Main project domain — staging / landing
{$EDGE_TUNNEL_FQDN} {
    reverse_proxy staging:80
}

# Forgejo — root path, no subpath rewrite needed
{$EDGE_TUNNEL_FQDN_FORGE} {
    reverse_proxy forgejo:3000
}

# Woodpecker CI — root path
{$EDGE_TUNNEL_FQDN_CI} {
    reverse_proxy woodpecker:8000
}
```

Those placeholders resolve to:

| Placeholder                 | Host                            |
|-----------------------------|---------------------------------|
| `{$EDGE_TUNNEL_FQDN}`       | `<project>.disinto.ai`          |
| `{$EDGE_TUNNEL_FQDN_FORGE}` | `forge.<project>.disinto.ai`    |
| `{$EDGE_TUNNEL_FQDN_CI}`    | `ci.<project>.disinto.ai`       |

**Compose file:** `docker/Caddyfile` (generated artifact, not in git). The
generator skips a file that already exists (`already exists, skipping`). That
file is what a compose backend mounts. Regenerating it does not change the
Nomad edge.

**Production (Nomad).** `nomad/jobs/edge.hcl` (header, around lines 30–33) is
the live edge: `disinto init --backend=nomad --with edge` deploys this job,
and the header says to change routing here, not in the compose Caddyfile
`lib/generators.sh` writes. The job template (around lines 180–217) is a
hardcoded `:80` subpath file (`/forge`, `/ci`, `/staging`, plus
`/api/engagement`) with `nomadService` upstreams. The job has no
`EDGE_ROUTING_MODE` or `EDGE_TUNNEL_FQDN*` env, so setting those variables
does not switch it.

The Caddy task uses `network_mode = "host"` (around line 130). Forgejo,
Woodpecker, and staging run in other alloc network namespaces, so loopback
and Docker DNS names are unreachable. A production pivot adds host blocks (or
an `EDGE_ROUTING_MODE` branch) to this template and keeps
`{{ range nomadService "forgejo" }}`, `"woodpecker"`, and `"staging"`
upstreams. Keep the `/api/engagement` handler. Do not copy the compose
blocks' `staging:80`, `forgejo:3000`, or `woodpecker:8000` dials into this
job.

### Service Configuration Changes

Compose citations in this table are the generator path. On the live stack,
Forgejo `ROOT_URL` is hardcoded in `nomad/jobs/forgejo.hcl`
(`FORGEJO__server__ROOT_URL`, around line 122, currently
`https://self.disinto.ai/forge/`) and Woodpecker's public host is hardcoded
in `nomad/jobs/woodpecker-server.hcl` (`WOODPECKER_HOST`, around line 140,
currently `https://self.disinto.ai/ci`). `lib/ci-setup.sh` does not rewrite
those job env blocks.

| Variable / Setting         | Current (subpath)                              | Fallback (subdomain)                            | Where it lives |
|----------------------------|------------------------------------------------|-------------------------------------------------|----------------|
| Forgejo `ROOT_URL`         | `https://<project>.disinto.ai/forge/`          | `https://forge.<project>.disinto.ai/`           | Compose sets `FORGEJO__server__ROOT_URL` from `FORGEJO_ROOT_URL` (`lib/generators.sh` around line 418; default `http://forgejo:3000/`). Subdomain mode does not rewrite this. Production value is `nomad/jobs/forgejo.hcl` around line 122. The running value is Forgejo `app.ini`. |
| `WOODPECKER_HOST`          | `http://localhost:8000` (compose / `ci-setup.sh`); live job is `https://self.disinto.ai/ci` | `https://ci.<project>.disinto.ai` | Compose: already selected in `lib/ci-setup.sh` around lines 170–178 when `EDGE_ROUTING_MODE=subdomain` and `EDGE_TUNNEL_FQDN_CI` is set. Production: `nomad/jobs/woodpecker-server.hcl` around line 140 — not switched by that branch. |
| Woodpecker OAuth redirect  | intended public URI `https://<project>.disinto.ai/ci/authorize`; `ci-setup.sh` default is `http://localhost:8000/authorize` | `https://ci.<project>.disinto.ai/authorize` | Compose: already selected in `lib/ci-setup.sh` around lines 156–159 under the same condition. That branch does not edit the Nomad job. |
| `EDGE_TUNNEL_FQDN`         | `<project>.disinto.ai`                         | unchanged (main domain)                         | Compose edge env, `lib/generators.sh` around line 678. Not emitted by `nomad/jobs/edge.hcl`. |

### Environment variables (compose generator only)

These are already written into the edge service environment block in
`lib/generators.sh` (block starts around line 661; the FQDN lines are around
678–683). They are empty unless the operator sets them. Filling them pivots
the compose generator and, for `EDGE_ROUTING_MODE`, `tools/edge-control`. It
does not add the keys, and it does not configure `nomad/jobs/edge.hcl`. The
old "~line 415" citation is the Forgejo volume mount, not this block.

| Variable                     | Value to set on a compose pivot     |
|------------------------------|-------------------------------------|
| `EDGE_ROUTING_MODE`          | `subdomain` (generator default `subpath`, around line 681) |
| `EDGE_TUNNEL_FQDN`           | `<project>.disinto.ai`              |
| `EDGE_TUNNEL_FQDN_FORGE`     | `forge.<project>.disinto.ai`        |
| `EDGE_TUNNEL_FQDN_CI`        | `ci.<project>.disinto.ai`           |

### DNS

`*.disinto.ai` is not enough. No new records are needed only if the registrar
supports `*.*.disinto.ai` wildcards. Otherwise, add explicit A/CNAME records
per project:

```
forge.<project>.disinto.ai  → edge server IP
ci.<project>.disinto.ai     → edge server IP
```

The edge server already handles TLS via Caddy's automatic HTTPS with the
existing ACME / DNS-01 challenge. The certificate must cover the new names;
the one-label wildcard does not.

### Edge Control (`tools/edge-control/register.sh`)

`do_register()` always adds one Caddy route for the main project host
(`add_route "$project"`, around line 201). When `EDGE_ROUTING_MODE=subdomain`
it also adds `forge.<project>` and `ci.<project>` beside that route (around
lines 203–210) and returns those hosts in the JSON `subdomains` object.
`do_deregister()` removes the main route and the per-service subdomain routes
in the same mode (around lines 268–279).

There is no TODO in `register.sh`, and no `--subdomain` flag to add. The
switch is `EDGE_ROUTING_MODE`.

`add_route()` in `tools/edge-control/lib/caddy.sh` (around line 63) already
treats its first argument as a host label and appends `.${DOMAIN_SUFFIX}`
(around line 66). `add_route "forge.${project}"` is how the forge subdomain
route is registered today. Subdomain support is not a missing feature of
`add_route()`. This is the tunnel registrar on the edge host. It is not a
substitute for the Nomad Caddyfile template above.

## Files to Change on Pivot

Already implemented — do not reimplement:

| File                              | Current state |
|-----------------------------------|---------------|
| `lib/generators.sh`               | Edge env already emits `EDGE_ROUTING_MODE`, `EDGE_TUNNEL_FQDN` (~678), `EDGE_TUNNEL_FQDN_FORGE` (~682), and `EDGE_TUNNEL_FQDN_CI` (~683). `_generate_caddyfile_impl` (~825) already calls `_generate_caddyfile_subdomain` (~881), which writes the three host blocks. Compose only — not the live edge. |
| `lib/ci-setup.sh`                 | Subdomain mode already sets the OAuth redirect (~156–159) and `WOODPECKER_HOST` (~170–178) from `EDGE_TUNNEL_FQDN_CI`. Does not edit Nomad job env. |
| `tools/edge-control/register.sh`  | `do_register()` already registers `forge.<project>` and `ci.<project>` beside the main route when `EDGE_ROUTING_MODE=subdomain` (~201–210). No TODO in this file. |
| `tools/edge-control/lib/caddy.sh` | `add_route()` already builds `<label>.${DOMAIN_SUFFIX}` (~63–66). Subdomain routes are extra `add_route` calls, not new API. |

Still required on a production pivot:

| File / setting                    | What changes |
|-----------------------------------|--------------|
| `nomad/jobs/edge.hcl`             | Live Caddyfile (template around lines 180–217). Add host blocks, or an `EDGE_ROUTING_MODE` branch, with `nomadService` upstreams. Keep `/api/engagement`. Do not regenerate `docker/Caddyfile` and do not paste Docker DNS dials (`staging:80`, `forgejo:3000`, `woodpecker:8000`) into this host-network job. |
| `nomad/jobs/forgejo.hcl`          | Set `FORGEJO__server__ROOT_URL` (around line 122) to `https://forge.<project>.disinto.ai/`. The compose `FORGEJO_ROOT_URL` default does not drive this job. |
| `nomad/jobs/woodpecker-server.hcl` | Set `WOODPECKER_HOST` (around line 140) to `https://ci.<project>.disinto.ai`, and point the OAuth redirect at `https://ci.<project>.disinto.ai/authorize`. `lib/ci-setup.sh` does not rewrite this job. |
| `EDGE_ROUTING_MODE`               | Set `subdomain` on the tunnel registrar (`tools/edge-control`) so `do_register()` adds the extra routes. Setting it only in the compose edge env does not change `nomad/jobs/edge.hcl`. |
| DNS                               | `*.*.disinto.ai`, or explicit records for `forge.` and `ci.` (see above). A one-label `*.disinto.ai` wildcard does not cover those names. |

Compose-backend only (not the live factory):

| File / setting                    | What changes |
|-----------------------------------|--------------|
| `EDGE_TUNNEL_FQDN*`               | Fill the three FQDNs in the compose edge env before regenerating. |
| `docker/Caddyfile`                | Generator will not overwrite an existing file. Replace or remove it, then regenerate under `EDGE_ROUTING_MODE=subdomain`. |
| `FORGEJO_ROOT_URL`                | Set to `https://forge.<project>.disinto.ai/` (`lib/generators.sh` compose env around line 418). Subdomain mode does not switch this by itself. |

Estimated effort for a full pivot: **under one day** given this plan. Route
registration and the compose Caddyfile shape are already behind the mode
switch. The production Caddyfile in `nomad/jobs/edge.hcl` is not.
