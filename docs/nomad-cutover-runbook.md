# Nomad Cutover Runbook

End-to-end procedure to cut over the disinto factory from docker-compose on
disinto-dev-box to Nomad on disinto-nomad-box.

**Target**: disinto-nomad-box (10.10.10.216) becomes production; disinto-dev-box
stays warm for rollback.

**Downtime budget**: <5 min blue-green flip.

**Data scope**: Forgejo issues + disinto-ops git bundle only. Everything else is
regenerated or discarded. OAuth secrets are regenerated on fresh init (all
sessions invalidated).

---

## 1. Pre-cutover readiness checklist

- [ ] Nomad + Vault stack healthy on a fresh wipe+init (step 5 verified)
- [ ] Codeberg mirror current — `git log` parity between dev-box Forgejo and
      Codeberg
- [ ] SSH key pair generated for nomad-box, registered on DO edge (see §4.6)
- [ ] Companion tools landed:
  - `disinto backup create` (#1057)
  - `disinto backup import` (#1058)
- [ ] Backup tarball produced and tested against a scratch LXC (see §3)

---

## 2. Pre-cutover artifact: backup

On disinto-dev-box:

```bash
./bin/disinto backup create /tmp/disinto-backup-$(date +%Y%m%d).tar.gz
```

Copy the tarball to nomad-box (and optionally to a local workstation for
safekeeping):

```bash
scp /tmp/disinto-backup-*.tar.gz nomad-box:/tmp/
```

---

## 3. Pre-cutover dry-run

On a throwaway LXC:

```bash
lxc launch ubuntu:24.04 cutover-dryrun
# inside the container:
disinto init --backend=nomad --import-env .env --with edge
./bin/disinto backup import /tmp/disinto-backup-*.tar.gz
```

Verify:

- Issue count matches source Forgejo
- disinto-ops repo refs match source bundle

Destroy the LXC once satisfied:

```bash
lxc delete cutover-dryrun --force
```

---

## 4. Cutover T-0 (operator executes; <5 min target)

### 4.1 Stop dev-box services

```bash
# On disinto-dev-box — stop, do NOT remove volumes (rollback needs them)
docker-compose stop
```

### 4.2 Provision nomad-box (if not already done)

```bash
# On disinto-nomad-box
disinto init --backend=nomad --import-env .env --with edge
```

### 4.3 Import backup

```bash
# On disinto-nomad-box
./bin/disinto backup import /tmp/disinto-backup-*.tar.gz
```

### 4.4 Configure Codeberg pull mirror

Manual, one-time step in the new Forgejo UI:

1. Create a mirror repository pointing at the Codeberg upstream
2. Confirm initial sync completes

### 4.5 Claude login

```bash
# On disinto-nomad-box
claude login
```

Set up Anthropic OAuth so agents can authenticate.

### 4.6 Autossh tunnel swap

> **Operator step** — cross-host, no dev-agent involvement. Do NOT automate.

1. Stop the tunnel on dev-box:
   ```bash
   # On disinto-dev-box
   systemctl stop reverse-tunnel
   ```

2. Copy or regenerate the tunnel unit on nomad-box:
   ```bash
   # Copy from dev-box, or let init regenerate it
   scp dev-box:/etc/systemd/system/reverse-tunnel.service \
       nomad-box:/etc/systemd/system/
   ```

3. Register nomad-box's public key on DO edge:
   ```bash
   # On DO edge box — same restricted-command as the dev-box key
   echo "<nomad-box-pubkey>" >> /home/johba/.ssh/authorized_keys
   ```

4. Start the tunnel on nomad-box:
   ```bash
   # On disinto-nomad-box
   systemctl enable --now reverse-tunnel
   ```

5. Verify end-to-end:
   ```bash
   curl https://self.disinto.ai/api/v1/version
   # Should return the new box's Forgejo version
   ```

### 4.7 Finalize local clone remote

The `/opt/disinto` clone was created during initial provisioning and still
points at the old dev-box Forgejo. Repoint it to the new instance.

```bash
# On disinto-nomad-box
./bin/disinto edge cutover-finalize --forge-host 10.10.10.132:3000
```

Idempotent — if origin already points at the new host, this is a no-op.

Verify:

```bash
git -C /opt/disinto remote -v | grep origin
# Should show 10.10.10.132:3000
grep dev-box /opt/disinto/.git/config && echo "FAIL: still points at old host" || echo "OK"
```

---

## 5. Post-cutover smoke

- [ ] `curl https://self.disinto.ai` → Forgejo welcome page
- [ ] Create a test PR → Woodpecker pipeline runs → agents assign and work
- [ ] Claude chat login via Forgejo OAuth succeeds

---

## 6. Rollback (if any step 4 gate fails)

1. Stop the tunnel on nomad-box:
   ```bash
   systemctl stop reverse-tunnel   # on nomad-box
   ```

2. Restore the tunnel on dev-box:
   ```bash
   systemctl start reverse-tunnel  # on dev-box
   ```

3. Bring dev-box services back up:
   ```bash
   docker-compose up -d            # on dev-box
   ```

4. DO Caddy config is unchanged — traffic restores in <5 min.

5. File a post-mortem issue. Keep nomad-box state intact for debugging.

---

## 7. Post-stable cleanup (T+1 week)

- `docker-compose down -v` on dev-box
- Archive `/var/lib/docker/volumes/disinto_*` to cold storage
- Delete disinto-dev-box LXC or keep as permanent rollback reserve (operator
  decision)
