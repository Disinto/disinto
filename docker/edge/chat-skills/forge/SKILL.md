# forge — Forgejo issue / PR / repo operations

> Trigger phrases: "issues", "open backlog", "PR list", "label", "file an
> issue", "comment on #N", "what's in the queue", "how much backlog",
> "show me #N".

This skill wraps the on-box Forgejo REST API at `$FORGE_URL` (rendered into
the edge container by the `local/forge.env` template in
`nomad/jobs/edge.hcl`) using `$FACTORY_FORGE_PAT` (rendered from
`kv/disinto/chat` by the `secrets/forge-pat` template stanza, loaded into
env by `docker/edge/entrypoint-edge.sh`). Tokens are guaranteed available —
do not ask the user to paste a credential; if the env var is empty, surface
the seeding command and stop.

## When to use

- Any read against issues, PRs, labels, branches, or repo metadata for
  `disinto-admin/disinto` (or any other repo on the on-box Forgejo).
- Labelling, commenting on, or filing issues / PRs.
- Listing branches and pull requests.

For raw curl against arbitrary Forgejo endpoints not covered by the helpers
below, the `forge-api` MCP server (see `docker/edge/chat-mcp.json`) is also
available — same token, structured tool surface.

## Read commands

| Command | Purpose |
| --- | --- |
| `list-issues.sh [--state open\|closed\|all] [--label <name>] [--limit N] [--repo <owner/name>]` | Paginate the issues API and emit one issue per line as `#<num> [labels] <title>`. Defaults: `--state open --limit 50 --repo $FORGE_REPO`. No label filter = all labels. |

## Write commands

(none in v1 — write skills land in subsequent slices, see #727.)

## Read vs write line

Read: free to invoke without confirmation.

Write (label, comment, branch create, issue file, PR merge): describe the
change, name the issue/PR, wait for the user to say "yes".

## Examples

User: "how many open backlog issues are there?"
→ `list-issues.sh --state open --label backlog | wc -l`
→ Report the count and the top 5 by issue number.

User: "what backlog do we have?"
→ `list-issues.sh --state open --label backlog --limit 100`
→ Render as a short prose summary, group by label suffix where useful.

User: "show me issue 542"
→ `curl -fsS -H "Authorization: token $FACTORY_FORGE_PAT" \
   "$FORGE_URL/api/v1/repos/disinto-admin/disinto/issues/542"`
→ Summarise title, state, labels, latest comment.

## Token & URL contract

- `FORGE_URL` — rendered by `local/forge.env` (Nomad service discovery,
  resolves to the live forgejo alloc address:port).
- `FACTORY_FORGE_PAT` — loaded from `/secrets/forge-pat` by
  `entrypoint-edge.sh` (`_chat_load_secret_file`), seeded by
  `tools/vault-seed-chat.sh` from `.env:FORGE_PAT`.
- `FORGE_REPO` — defaults to `disinto-admin/disinto`. Override via env
  to target other repos on the same Forgejo.

If any of the above is empty:

- `FORGE_URL` empty → check `nomad alloc status edge` and the
  `local/forge.env` template render.
- `FACTORY_FORGE_PAT` empty → run
  `tools/vault-seed-chat.sh` on the host with `FORGE_PAT` set in `.env`,
  then `nomad job restart edge` to pick up the re-rendered secret.
