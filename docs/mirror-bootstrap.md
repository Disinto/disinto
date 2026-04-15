# Mirror Bootstrap — Pull-Mirror Cutover Path

How to populate an empty Forgejo repo from an external source using
`lib/mirrors.sh`'s `mirror_pull_register()`.

## Prerequisites

| Variable | Example | Purpose |
|---|---|---|
| `FORGE_URL` | `http://forgejo:3000` | Forgejo instance base URL |
| `FORGE_API` | `${FORGE_URL}/api/v1` | API base (set by `lib/env.sh`) |
| `FORGE_TOKEN` | (admin or org-owner token) | Must have `repo:create` scope |

The target org/user must already exist on the Forgejo instance.

## Command

```bash
source lib/env.sh
source lib/mirrors.sh

# Register a pull mirror — creates the repo and starts the first sync.
mirror_pull_register \
  "https://codeberg.org/johba/disinto.git" \   # source URL
  "disinto-admin" \                             # target owner
  "disinto" \                                   # target repo name
  "8h0m0s"                                      # sync interval (optional, default 8h)
```

The function calls `POST /api/v1/repos/migrate` with `mirror: true`.
Forgejo creates the repo and immediately queues the first sync.

## Verifying the sync

```bash
# Check mirror status via API
forge_api GET "/repos/disinto-admin/disinto" | jq '.mirror, .mirror_interval'

# Confirm content arrived — should list branches
forge_api GET "/repos/disinto-admin/disinto/branches" | jq '.[].name'
```

The first sync typically completes within a few seconds for small-to-medium
repos.  For large repos, poll the branches endpoint until content appears.

## Cutover scenario (Nomad migration)

At cutover to the Nomad box:

1. Stand up fresh Forgejo on the Nomad cluster (empty instance).
2. Create the `disinto-admin` org via `disinto init` or API.
3. Run `mirror_pull_register` pointing at the Codeberg source.
4. Wait for sync to complete (check branches endpoint).
5. Once content is confirmed, proceed with `disinto init` against the
   now-populated repo — all subsequent `mirror_push` calls will push
   to any additional mirrors configured in `projects/*.toml`.

No manual `git clone` + `git push` step is needed.  The Forgejo pull-mirror
handles the entire transfer.
