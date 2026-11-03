#!/usr/bin/env bash
# =============================================================================
# machine/machine-sense.sh — a read-only report of the machine the disinto box
# runs on
#
# Runs ON THE MACHINE that hosts the box (the LXD host), never in the box or
# in an agent. A systemd timer (machine/disinto-machine-sense.timer) runs it
# every 10 minutes as root. It reads; the only files it writes are its own:
#
#   ${MACHINE_SENSE_SHARE}/machine.json   the report, mode 0644, replaced
#                                          atomically (temp file + mv)
#   ${MACHINE_SENSE_STATE}/folders.jsonl  folder-size snapshots, kept 8 days
#
# machine/install.sh mounts the share directory read-only into the box at
# /srv/disinto/machine: the box reads what this script publishes and cannot
# touch the machine. The report carries sizes and names, never file contents.
#
# Report (schema 1):
#   schema, t, errors[]   errors: the sections that could not be read
#   volumes[]      df: source, fstype, mount, size_b, used_b, avail_b, used_pct
#   unallocated[]  vgs: vg, size_b, free_b (space given to no volume yet)
#   memory         /proc/meminfo: total_b, available_b, swap_total_b,
#                  swap_free_b
#   cpu            count, load1, load5, load15
#   containers[]   lxc: name, status, memory_b, limit_memory, limit_cpu
#   processes[]    the 5 largest by RSS: comm, rss_b (command name, no args)
#   folders[]      each child of each MACHINE_SENSE_FOLDER_ROOTS entry: root,
#                  name, size_b, measured, growth_b_per_day (null without a
#                  snapshot 12 h to 8 days older than the current one)
#   neighbours[]   MACHINE_SENSE_NEIGHBOURS lines "path<TAB>owner<TAB>note":
#                  who else lives on the machine, written by its owner
#
# du takes minutes on a busy terabyte, so folder sizes are measured at most
# every MACHINE_SENSE_FOLDERS_EVERY_S, at idle IO priority; in between, the
# report repeats the last snapshot with its `measured` time.
#
# Env (defaults):
#   MACHINE_SENSE_SHARE            /var/lib/disinto-machine/share
#   MACHINE_SENSE_STATE            /var/lib/disinto-machine/state
#   MACHINE_SENSE_NEIGHBOURS       /etc/disinto-machine/neighbours.tsv
#   MACHINE_SENSE_FOLDER_ROOTS     /opt/ai (space-separated list)
#   MACHINE_SENSE_FOLDERS_EVERY_S  21600
#   MACHINE_SENSE_PROC             /proc
#   MACHINE_SENSE_NOW              now, epoch seconds (tests)
#
# Exit 0 when the report was written; a reader that fails leaves its section
# empty and is named in errors[]. Exit 1 when jq is missing or the share or
# state directory cannot be created. No network. Not an agent: does not
# source lib/env.sh.
# =============================================================================
set -euo pipefail

SHARE="${MACHINE_SENSE_SHARE:-/var/lib/disinto-machine/share}"
STATE="${MACHINE_SENSE_STATE:-/var/lib/disinto-machine/state}"
NEIGHBOURS="${MACHINE_SENSE_NEIGHBOURS:-/etc/disinto-machine/neighbours.tsv}"
ROOTS="${MACHINE_SENSE_FOLDER_ROOTS:-/opt/ai}"
EVERY="${MACHINE_SENSE_FOLDERS_EVERY_S:-21600}"
PROC="${MACHINE_SENSE_PROC:-/proc}"
NOW="${MACHINE_SENSE_NOW:-$(date -u +%s)}"
KEEP_S=691200   # folder snapshots older than 8 days are dropped

if ! command -v jq >/dev/null 2>&1; then
  echo "machine-sense: jq is missing" >&2
  exit 1
fi
if ! mkdir -p "$SHARE" "$STATE" 2>/dev/null; then
  echo "machine-sense: cannot create $SHARE or $STATE" >&2
  exit 1
fi

work="$(mktemp -d)"
tmp=""
# A failed run must not leave a half-written report in the share the box reads.
trap 'rm -rf "$work"; if [ -n "$tmp" ]; then rm -f "$tmp"; fi' EXIT
errors=()

read_volumes() {
  df -B1 --output=source,fstype,target,size,used,avail \
      -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs \
    | awk 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {source: .[0], fstype: .[1], mount: .[2], size_b: (.[3] | tonumber),
           used_b: (.[4] | tonumber), avail_b: (.[5] | tonumber)}
        | .used_pct = (if (.used_b + .avail_b) > 0
                       then (.used_b * 100 / (.used_b + .avail_b) | ceil)
                       else null end))'
}

read_unallocated() {
  vgs --noheadings --units b --nosuffix --separator "$(printf '\t')" \
      -o vg_name,vg_size,vg_free \
    | jq -R -s -c 'split("\n") | map(gsub("^\\s+|\\s+$"; "")
        | select(length > 0) | split("\t")
        | {vg: .[0], size_b: (.[1] | tonumber), free_b: (.[2] | tonumber)})'
}

read_memory() {
  awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { kb[$1] = $2 }
       END {
         printf "{\"total_b\":%.0f,\"available_b\":%.0f,", \
                kb["MemTotal:"] * 1024, kb["MemAvailable:"] * 1024
         printf "\"swap_total_b\":%.0f,\"swap_free_b\":%.0f}\n", \
                kb["SwapTotal:"] * 1024, kb["SwapFree:"] * 1024
       }' "$PROC/meminfo"
}

read_cpu() {
  local count l1 l5 l15 rest
  count="$(nproc)"
  read -r l1 l5 l15 rest < "$PROC/loadavg"
  jq -n -c --argjson n "$count" --argjson a "$l1" --argjson b "$l5" \
     --argjson c "$l15" '{count: $n, load1: $a, load5: $b, load15: $c}'
}

read_containers() {
  lxc list --format json \
    | jq -c 'map({name, status, memory_b: (.state.memory.usage // null),
                  limit_memory: (.config["limits.memory"] // null),
                  limit_cpu: (.config["limits.cpu"] // null)})'
}

read_processes() {
  # awk, not head: head would close the pipe early and fail it under pipefail.
  ps -eo rss=,comm= --sort=-rss \
    | awk 'NR <= 5' \
    | jq -R -s -c 'split("\n") | map(select(length > 0)
        | capture("^\\s*(?<rss>[0-9]+)\\s+(?<comm>.*)$")
        | {comm, rss_b: ((.rss | tonumber) * 1024)})'
}

read_neighbours() {
  if [ ! -f "$NEIGHBOURS" ]; then
    echo '[]'
    return 0
  fi
  jq -R -s -c 'split("\n")
    | map(select(length > 0 and (startswith("#") | not)) | split("\t")
          | {path: .[0], owner: (.[1] // ""), note: (.[2] // "")})' \
    "$NEIGHBOURS"
}

# Measure each folder root whose last snapshot is older than EVERY, append
# the snapshot, and drop snapshots older than KEEP_S.
update_folders() {
  local root last io=()
  local snaps="$STATE/folders.jsonl"
  if command -v ionice >/dev/null 2>&1; then
    io=(ionice -c 3)
  fi
  touch "$snaps"
  for root in $ROOTS; do
    last="$(jq -s -r --arg r "$root" \
              '[.[] | select(.root == $r) | .t] | max // 0' "$snaps")" || last=0
    if [ $(( NOW - last )) -lt "$EVERY" ]; then
      continue
    fi
    if [ ! -d "$root" ]; then
      errors+=("folders:$root")
      continue
    fi
    # du exits non-zero when a file vanishes mid-walk; its output still counts.
    { nice -n 19 ${io[@]+"${io[@]}"} du -x -B1 --max-depth=1 "$root" \
        2>/dev/null || true; } \
      | jq -R -s -c --arg root "$root" --argjson t "$NOW" '
          split("\n") | map(select(length > 0) | split("\t")
            | {path: .[1], size_b: (.[0] | tonumber)})
          | map(select(.path != $root))
          | {t: $t, root: $root,
             sizes: (map({key: (.path | ltrimstr($root + "/")),
                          value: .size_b}) | from_entries)}' \
      > "$work/snap.json" || true
    if [ "$(jq '.sizes | length' "$work/snap.json" 2>/dev/null || echo 0)" -gt 0 ]; then
      cat "$work/snap.json" >> "$snaps"
    else
      errors+=("folders:$root")
    fi
  done
  if jq -c --argjson cut $(( NOW - KEEP_S )) 'select(.t >= $cut)' "$snaps" \
       > "$work/keep.jsonl"; then
    cat "$work/keep.jsonl" > "$snaps"
  fi
}

# The latest snapshot per root, with growth against the snapshot closest to
# one day before it (12 h to 8 days back).
read_folders() {
  jq -s -c --arg roots "$ROOTS" '
    ($roots | split(" ") | map(select(length > 0))) as $rs
    | [ $rs[] as $r
        | ([.[] | select(.root == $r)] | sort_by(.t)) as $snaps
        | ($snaps | last) as $cur
        | select($cur != null)
        | ([$snaps[] | select(($cur.t - .t) >= 43200
                              and ($cur.t - .t) <= 691200)]
           | min_by(($cur.t - .t - 86400) | fabs)) as $old
        | $cur.sizes | to_entries[]
        | {root: $r, name: .key, size_b: .value, measured: ($cur.t | todate),
           growth_b_per_day:
             (if $old == null or $old.sizes[.key] == null then null
              else ((.value - $old.sizes[.key]) * 86400 / ($cur.t - $old.t)
                    | floor) end)} ]
    | sort_by(-.size_b)' "$STATE/folders.jsonl"
}

# section NAME DEFAULT READER — the reader's stdout must be one JSON value;
# otherwise the section is DEFAULT and NAME goes to errors[].
section() {
  local out="$work/$1.json"
  if "$3" > "$out" 2>/dev/null && jq -e . "$out" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' "$2" > "$out"
  errors+=("$1")
}

section volumes '[]' read_volumes
section unallocated '[]' read_unallocated
section memory '{}' read_memory
section cpu '{}' read_cpu
section containers '[]' read_containers
section processes '[]' read_processes
section neighbours '[]' read_neighbours
update_folders
section folders '[]' read_folders

errors_json="$(printf '%s\n' ${errors[@]+"${errors[@]}"} \
  | jq -R -s -c 'split("\n") | map(select(length > 0))')"

tmp="$(mktemp "$SHARE/.machine.json.XXXXXX")"
jq -n --argjson t "$NOW" --argjson errors "$errors_json" \
   --slurpfile volumes "$work/volumes.json" \
   --slurpfile unallocated "$work/unallocated.json" \
   --slurpfile memory "$work/memory.json" \
   --slurpfile cpu "$work/cpu.json" \
   --slurpfile containers "$work/containers.json" \
   --slurpfile processes "$work/processes.json" \
   --slurpfile folders "$work/folders.json" \
   --slurpfile neighbours "$work/neighbours.json" \
   '{schema: 1, t: ($t | todate), errors: $errors,
     volumes: $volumes[0], unallocated: $unallocated[0], memory: $memory[0],
     cpu: $cpu[0], containers: $containers[0], processes: $processes[0],
     folders: $folders[0], neighbours: $neighbours[0]}' > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$SHARE/machine.json"
