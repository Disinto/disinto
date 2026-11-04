# machine/ — the machine sense

Everything in this directory runs on the machine that hosts the disinto
box (the LXD host), not in the box and not in an agent.

**Why.** The box is an LXD container. From inside it, a disk check sees
the whole volume the box is stored on but not who uses it, and memory
reads the box's own cap, not the machine's. The supervisor's
disk-pressure fix pruned Docker for a volume that other projects were
filling, because it could not tell.

**What.** `machine-sense.sh` runs every 10 minutes from a systemd timer
and writes `machine.json`:
- volumes and the space no volume has yet;
- memory, CPU and load;
- LXD containers, and the largest processes by command name;
- folder sizes with growth per day;
- the neighbours the machine's owner lists in
  `/etc/disinto-machine/neighbours.tsv`.

The schema is in the script's header. The report has sizes and names,
never file contents.

**The folder roots.** `folders[]` lists only the **direct children** of
each `MACHINE_SENSE_FOLDER_ROOTS` root (`du --max-depth=1`). The box's
own folder lives one level deeper, at
`/opt/ai/lxd/containers/<box-name>`, so the installed unit sets
`MACHINE_SENSE_FOLDER_ROOTS="/opt/ai /opt/ai/lxd/containers"` by
default (#2094). Without the deep root the supervisor's Disk owner gate
(#2077) never finds the entry named `${MACHINE_BOX_NAME:-disinto-nomad-box}`
and falls back to the `/opt/ai` + `lxd` upper bound, blaming the box for
all of LXD's disk. If the box lives elsewhere, add its parent folder to
the same variable.

**How the box sees it.** `install.sh` mounts the report's directory into
the box read-only, at `/srv/disinto/machine/machine.json`. The box can
read the report and cannot touch the machine. No key, socket or
credential crosses.

**Install** (once, as root on the machine, from a disinto checkout):

```bash
sudo machine/install.sh            # box name defaults to disinto-nomad-box
```

The install is idempotent. Edit `/etc/disinto-machine/neighbours.tsv`
afterwards to say who else lives on the machine. Tests:
`bats tests/machine-sense.bats`.
