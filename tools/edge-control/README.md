# Porter — the public door of a deployment

Porter is the public door of a deployment: one SSH account, identified
by the caller's key **fingerprint**, plus, later, HTTPS routes. It is
**not** the Nomad `edge` job and **not** `docker/edge/dispatcher.sh`.
Those manage reverse tunnels and the factory's own edge services; Porter
only opens the door.

## Install the door

On the jump host, from the repo on the matching branch:

```bash
bash tools/edge-control/porter-install.sh
# optionally, seed an admin row from a pubkey:
bash tools/edge-control/porter-install.sh --admin-key ~/.ssh/id_ed25519.pub
```

`install.sh` is the optional Caddy half (routes, certs, DNS plugin) —
it is **not** the door. `jev` never needs Caddy or a Gandi token.
`porter-install.sh` copies the door, seeds the ledger, creates the
`porter` user, writes the sshd drop-in, and never reloads sshd —
`systemctl reload ssh` is operator work.

## sshd: a drop-in only

The sshd config is the `Match User porter` drop-in at
`/etc/ssh/sshd_config.d/porter.conf` — a per-account block. That block,
and only that block, carries the `AuthorizedKeysCommand`, confined to the
`porter` account. Never a global `AuthorizedKeysCommand` on the jump host.

## Secrets

The TypeSafe key and model live in `/etc/porter/porter.env`,
mode `640`, assignment lines only (`KEY=VALUE` — no comments, no exports):

```env
TYPESAFE_API_KEY=
JEV_MODEL=jev-1.13.0
```

- The TypeSafe key stays in the env file. It does not go in git
  or on the factory.
- `JEV_MODEL` stays `jev-1.13.0` (pinned); `jev-latest` moves.
- `porter-install.sh` creates the file only if absent and never
  rewrites its contents; it tightens a loose mode back to `640`.

## Admin and health

```bash
# read-only health check
bash tools/edge-control/porter-doctor.sh
# grant admin — on the host, as root, local only
bash tools/edge-control/porter-admin.sh add-admin <fingerprint>
```

- `porter-doctor.sh` is read-only. It exits 0 only if every check is `ok`.
- `porter-admin.sh add-admin <fingerprint>` grants admin on the local
  ledger, on the host, as root. There is no remote admin verb.

## Calling the door

An approved caller (fingerprint in the ledger, status `approved`,
at least 1 credit) runs, with state on stdin:

```bash
ssh porter@<host> jev <pack> < state
```

- Stdin is state: max 32768 bytes, no NUL bytes.
- Questions come from `packs/<pack>.json` only — never from stdin.
- One credit is debited only when the final HTTP status is 200 and
  the body is JSON with an `answers` object.
- Noul values are probabilities. Porter does not threshold them.

## Paths

Source tree stays `tools/edge-control` for now.
Installed paths are `/opt/porter` and `/var/lib/porter`.
