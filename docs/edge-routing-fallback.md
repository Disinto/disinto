# Edge Routing Fallback: Per-Project Subdomains

> **Status:** Contingency plan. Only implement if subpath routing (#704 / #708)
> proves unworkable. The mode switch and the subdomain routes are already in
> the tree behind `EDGE_ROUTING_MODE=subdomain` (default `subpath`). A pivot
> sets that mode and the FQDNs; it does not reimplement registration.

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

The wildcard cert from #621 already covers `*.<project>.disinto.ai` — no new
DNS records or certs are needed for sub-subdomains because `*.disinto.ai`
matches one level deep. For sub-subdomains like `forge.<project>.disinto.ai`
we would need to add a second wildcard (`*.*.disinto.ai`) or explicit DNS
records per project. Both are straightforward with the existing Gandi DNS-01
setup.

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

`lib/generators.sh:_generate_caddyfile_impl` (around line 825) already branches
on `EDGE_ROUTING_MODE`. In `subdomain` mode it calls
`_generate_caddyfile_subdomain` (around line 881), which writes three host
blocks. Do not hand-roll a second generator. The blocks use Caddy env
placeholders:

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

| Placeholder              | Host                              |
|--------------------------|-----------------------------------|
| `{$EDGE_TUNNEL_FQDN}`    | `<project>.disinto.ai`            |
| `{$EDGE_TUNNEL_FQDN_FORGE}` | `forge.<project>.disinto.ai`   |
| `{$EDGE_TUNNEL_FQDN_CI}` | `ci.<project>.disinto.ai`         |

**Current file:** `docker/Caddyfile` (generated artifact, not in git). The
generator skips a file that already exists (`already exists, skipping`), so a
pivot on a live install still replaces or removes `docker/Caddyfile` and
regenerates with `EDGE_ROUTING_MODE=subdomain`.

### Service Configuration Changes

| Variable / Setting         | Current (subpath)                              | Fallback (subdomain)                            | Where it lives |
|----------------------------|------------------------------------------------|-------------------------------------------------|----------------|
| Forgejo `ROOT_URL`         | `https://<project>.disinto.ai/forge/`          | `https://forge.<project>.disinto.ai/`           | Compose sets `FORGEJO__server__ROOT_URL` from `FORGEJO_ROOT_URL` (`lib/generators.sh` around line 418; default `http://forgejo:3000/`). Subdomain mode does not rewrite this — set `FORGEJO_ROOT_URL` on pivot. The running value is Forgejo `app.ini`. |
| `WOODPECKER_HOST`          | `http://localhost:8000` (subpath via proxy)     | `https://ci.<project>.disinto.ai`               | Already selected in `lib/ci-setup.sh` around lines 170–178 when `EDGE_ROUTING_MODE=subdomain` and `EDGE_TUNNEL_FQDN_CI` is set. |
| Woodpecker OAuth redirect  | intended public URI `https://<project>.disinto.ai/ci/authorize`; code default is `http://localhost:8000/authorize` | `https://ci.<project>.disinto.ai/authorize` | Already selected in `lib/ci-setup.sh` around lines 156–159 under the same condition. |
| `EDGE_TUNNEL_FQDN`         | `<project>.disinto.ai`                         | unchanged (main domain)                         | `lib/generators.sh` around line 678 |

### Environment variables (already emitted)

These are already written into the edge service environment block in
`lib/generators.sh` (block starts around line 661; the FQDN lines are around
678–683). They are empty unless the operator sets them. A pivot fills the
values; it does not add the keys. The old "~line 415" citation is the Forgejo
volume mount, not this block.

| Variable                     | Value to set on pivot                  |
|------------------------------|----------------------------------------|
| `EDGE_ROUTING_MODE`          | `subdomain` (generator default `subpath`, around line 681) |
| `EDGE_TUNNEL_FQDN`           | `<project>.disinto.ai`                 |
| `EDGE_TUNNEL_FQDN_FORGE`     | `forge.<project>.disinto.ai`           |
| `EDGE_TUNNEL_FQDN_CI`        | `ci.<project>.disinto.ai`              |

### DNS

No new records needed if the registrar supports `*.*.disinto.ai` wildcards.
Otherwise, add explicit A/CNAME records per project:

```
forge.<project>.disinto.ai  → edge server IP
ci.<project>.disinto.ai     → edge server IP
```

The edge server already handles TLS via Caddy's automatic HTTPS with the
existing ACME / DNS-01 challenge.

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
route is registered today. Subdomain support is not a missing feature.

## Files to Change on Pivot

Already implemented — do not reimplement:

| File                              | Current state |
|-----------------------------------|---------------|
| `lib/generators.sh`               | Edge env already emits `EDGE_ROUTING_MODE`, `EDGE_TUNNEL_FQDN` (~678), `EDGE_TUNNEL_FQDN_FORGE` (~682), and `EDGE_TUNNEL_FQDN_CI` (~683). `_generate_caddyfile_impl` (~825) already calls `_generate_caddyfile_subdomain` (~881), which writes the three host blocks. |
| `lib/ci-setup.sh`                 | Subdomain mode already sets the OAuth redirect (~156–159) and `WOODPECKER_HOST` (~170–178) from `EDGE_TUNNEL_FQDN_CI`. |
| `tools/edge-control/register.sh`  | `do_register()` already registers `forge.<project>` and `ci.<project>` beside the main route when `EDGE_ROUTING_MODE=subdomain` (~201–210). No TODO in this file. |
| `tools/edge-control/lib/caddy.sh` | `add_route()` already builds `<label>.${DOMAIN_SUFFIX}` (~63–66). Subdomain routes are extra `add_route` calls, not new API. |

Still required on pivot (configuration, not missing helpers):

| File / setting                    | What changes |
|-----------------------------------|--------------|
| `EDGE_ROUTING_MODE` and the three `EDGE_TUNNEL_FQDN*` values | Set mode to `subdomain` and fill the FQDNs before regenerating the Caddyfile and re-running register. |
| `docker/Caddyfile`                | Generator will not overwrite an existing file. Replace or remove it, then regenerate under `EDGE_ROUTING_MODE=subdomain`. |
| `FORGEJO_ROOT_URL`                | Set to `https://forge.<project>.disinto.ai/` (`lib/generators.sh` compose env around line 418). Subdomain mode does not switch this by itself. |
| DNS                               | `*.*.disinto.ai`, or explicit records for `forge.` and `ci.` (see above). |

Estimated effort for a full pivot: **under one day** given this plan — the
route registration, Caddyfile shape, and edge env keys are already behind the
mode switch.
