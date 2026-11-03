#!/usr/bin/env bats
# =============================================================================
# tests/machine-sense.bats — machine/machine-sense.sh writes the machine report
#
# Hermetic: every reader (df, vgs, lxc, ps, nproc, du) is a stub on PATH, and
# /proc is a fixture directory. No root, no LXD, no real disk walk.
# =============================================================================

stub() {
  { printf '#!/usr/bin/env bash\n'; cat; } > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/machine/machine-sense.sh"
  T="$(mktemp -d)"
  mkdir -p "$T/bin" "$T/proc" "$T/ai"
  export PATH="$T/bin:$PATH"
  export MACHINE_SENSE_SHARE="$T/share"
  export MACHINE_SENSE_STATE="$T/state"
  export MACHINE_SENSE_NEIGHBOURS="$T/neighbours.tsv"
  export MACHINE_SENSE_FOLDER_ROOTS="$T/ai"
  export MACHINE_SENSE_PROC="$T/proc"
  export MACHINE_SENSE_NOW=1793700000
  export DU_LOG="$T/du.log"
  REPORT="$T/share/machine.json"

  printf '%s\n' 'MemTotal:       65000000 kB' 'MemAvailable:   14000000 kB' \
    'SwapTotal:       8000000 kB' 'SwapFree:        6000000 kB' \
    > "$T/proc/meminfo"
  printf '10.67 10.56 11.49 15/2578 2517439\n' > "$T/proc/loadavg"

  stub df <<'EOF'
printf 'Filesystem Type Mounted 1B-blocks Used Avail\n'
printf '/dev/mapper/vg-ai ext4 /opt/ai 1000 810 190\n'
printf '/dev/sda1 ext4 /mnt/scratch 500 0 500\n'
EOF
  stub vgs <<'EOF'
printf '  vg\t2000\t630\n'
EOF
  stub lxc <<'EOF'
cat <<'JSON'
[{"name":"box","status":"Running","state":{"memory":{"usage":2000}},
  "config":{"limits.memory":"8GiB","limits.cpu":"4"}},
 {"name":"other","status":"Stopped","state":null,"config":{}}]
JSON
EOF
  stub ps <<'EOF'
printf '%s\n' '29442760 strata-host' '15962112 python' '9 a' '8 b' '7 c' '6 d'
EOF
  stub nproc <<'EOF'
echo 12
EOF
  stub du <<'EOF'
root="${*: -1}"
echo "du $root" >> "$DU_LOG"
printf '%s\t%s\n' 600 "$root/research" 200 "$root/models" 810 "$root"
EOF
}

teardown() {
  rm -rf "$T"
}

@test "writes a report with every section" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$REPORT" ]
  [ "$(jq -r '.schema' "$REPORT")" = "1" ]
  [ "$(jq -r '.t' "$REPORT")" = "2026-11-03T10:00:00Z" ]
  [ "$(jq -c '.errors' "$REPORT")" = "[]" ]
  [ "$(jq -r '.volumes[0].mount' "$REPORT")" = "/opt/ai" ]
  [ "$(jq -r '.volumes[0].used_pct' "$REPORT")" = "81" ]
  [ "$(jq -r '.volumes | length' "$REPORT")" = "2" ]
  [ "$(jq -r '.unallocated[0].free_b' "$REPORT")" = "630" ]
  [ "$(jq -r '.memory.available_b' "$REPORT")" = "14336000000" ]
  [ "$(jq -r '.cpu.count' "$REPORT")" = "12" ]
  [ "$(jq -r '.cpu.load1' "$REPORT")" = "10.67" ]
  [ "$(jq -r '.containers | length' "$REPORT")" = "2" ]
  [ "$(jq -r '.containers[0].limit_memory' "$REPORT")" = "8GiB" ]
  [ "$(jq -r '.containers[1].memory_b' "$REPORT")" = "null" ]
  [ "$(jq -r '.processes | length' "$REPORT")" = "5" ]
  [ "$(jq -r '.processes[0].comm' "$REPORT")" = "strata-host" ]
  [ "$(jq -r '.folders[0].name' "$REPORT")" = "research" ]
  [ "$(jq -r '.folders[0].size_b' "$REPORT")" = "600" ]
  [ "$(jq -r '.folders[0].growth_b_per_day' "$REPORT")" = "null" ]
}

@test "the report is world-readable and no temp file is left" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$REPORT")" = "644" ]
  [ "$(ls -A "$T/share")" = "machine.json" ]
}

@test "growth per day reads the snapshot closest to a day earlier" {
  mkdir -p "$T/state"
  jq -n -c --arg r "$T/ai" --argjson t $(( MACHINE_SENSE_NOW - 86400 )) \
    '{t: $t, root: $r, sizes: {research: 400, models: 200}}' \
    > "$T/state/folders.jsonl"
  jq -n -c --arg r "$T/ai" --argjson t $(( MACHINE_SENSE_NOW - 9 * 86400 )) \
    '{t: $t, root: $r, sizes: {research: 1}}' >> "$T/state/folders.jsonl"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.folders[] | select(.name == "research") | .growth_b_per_day' "$REPORT")" = "200" ]
  [ "$(jq -r '.folders[] | select(.name == "models") | .growth_b_per_day' "$REPORT")" = "0" ]
  # the nine-day-old snapshot is dropped
  [ "$(jq -s 'map(select(.sizes.research == 1)) | length' "$T/state/folders.jsonl")" = "0" ]
}

@test "du runs at most once per MACHINE_SENSE_FOLDERS_EVERY_S" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  MACHINE_SENSE_NOW=$(( MACHINE_SENSE_NOW + 600 )) run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DU_LOG")" -eq 1 ]
  [ "$(jq -r '.folders[0].measured' "$REPORT")" = "2026-11-03T10:00:00Z" ]
  MACHINE_SENSE_NOW=$(( MACHINE_SENSE_NOW + 21600 )) run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DU_LOG")" -eq 2 ]
}

@test "a failing reader is named in errors and the report is still written" {
  stub lxc <<'EOF'
exit 1
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.containers' "$REPORT")" = "[]" ]
  [ "$(jq -c '.errors' "$REPORT")" = '["containers"]' ]
  [ "$(jq -r '.volumes[0].mount' "$REPORT")" = "/opt/ai" ]
}

@test "a missing folder root is an error, not a failure" {
  export MACHINE_SENSE_FOLDER_ROOTS="$T/nowhere"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.folders' "$REPORT")" = "[]" ]
  [ "$(jq -r '.errors | index("folders:'"$T"'/nowhere") != null' "$REPORT")" = "true" ]
}

@test "neighbours: one entry per line, comments skipped" {
  printf '# path\towner\tnote\n/opt/ai/research\towner\tcleans up its own disk\n' \
    > "$MACHINE_SENSE_NEIGHBOURS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.neighbours' "$REPORT")" = '[{"path":"/opt/ai/research","owner":"owner","note":"cleans up its own disk"}]' ]
}

@test "no neighbours file gives an empty list" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.neighbours' "$REPORT")" = "[]" ]
}

@test "a share directory that cannot be created exits 1" {
  printf 'x' > "$T/file"
  MACHINE_SENSE_SHARE="$T/file/share" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}
