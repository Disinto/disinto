# RESOURCES.md — Factory infrastructure inventory
# Copy to RESOURCES.md and fill in your actual values.
# RESOURCES.md is gitignored — never commit real hostnames, IPs, or credentials.

## Compute

### <host-alias>
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
