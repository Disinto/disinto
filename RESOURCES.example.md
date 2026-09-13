# RESOURCES.md — Factory infrastructure inventory
# Copy to RESOURCES.md and fill in your actual values.
# RESOURCES.md is gitignored — never commit real hostnames, IPs, or credentials.

## Compute

Structured host blocks are what `lib/resources.sh` parses: a `### <alias>`
heading with `- class:` (meep | cpu | gpu | control), `- ssh:`, `- cap:`
(max concurrent jobs), and an optional `- image:` (default image). Wave 2's
`run-experiment.sh` picks the first matching-class host whose in-flight count
is below `cap` — no other placement policy. Prose bullets (Specs / Location /
Access / …) stay for humans and are ignored by the parser.

### <host-alias>
- class: cpu
- ssh: user@example.com
- cap: 2
- image: ghcr.io/myorg/edge:local
- **Specs**: e.g. 8 GB RAM, 4 vCPU, 80 GB disk
- **Location**: e.g. region / datacenter
- **Access**: e.g. `ssh user@host-alias` (key in ~/.ssh/id_ed25519)
- **Running**: list current workloads, e.g. woodpecker-ci, disinto, postgres
- **Available for**: what it can still absorb, e.g. staging deploy, build cache
- **Projects**: which projects use this host, e.g. myorg/myproject

### <host-alias-2>
- **Specs**:
- **Location**:
- **Access**:
- **Running**:
- **Available for**:
- **Projects**:

## Domains

| Domain | Status | Project | Notes |
|--------|--------|---------|-------|
| example.com | active | myorg/myproject | main domain, auto-renew on |
| staging.example.com | active | myorg/myproject | points to staging server |

## External accounts

| Service | Purpose | Limits |
|---------|---------|--------|
| Forge (Forgejo) | source hosting + CI triggers | 10 GB storage, 1000 min/mo CI |
| Anthropic | Claude API | $X/mo budget, rate limit: 100k TPM |
| Cloudflare | DNS + CDN | free tier |

## Budget

- **Compute**: e.g. €20/mo cap — current spend €12/mo (2 VPS)
- **Domains**: e.g. €30/yr — next renewal: 2025-11-01
- **APIs**: e.g. $50/mo Anthropic — alert at $40
- **Other**: any other constraints

## llama

Machine-readable lease of the llama-server slots (AD-002: with `--kv-unified`
the KV pool is shared, so the slots are a budget, not per-box capacity).
Parsed by `lib/resources.sh`: `resources_llama_slots` / `resources_llama_held`
/ `resources_llama_free` (free = slots − the holder counts below). One
`- holder:` line per in-flight lease; the integer after the holder name is
how many slots it holds. Omit this whole section when there is no llama
backend — a file without `## llama` is valid.

- slots: 4
- holder: nomad-box 2
- holder: selenocyte-box 1
