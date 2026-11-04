#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2094.sh
#
# Issue #2094: machine-sense lists only the direct children of each
# MACHINE_SENSE_FOLDER_ROOTS root (du --max-depth=1), so the box's own
# folder, at /opt/ai/lxd/containers/<box>, never landed in folders[] on the
# live layout. disk_owner_line (supervisor/preflight.sh, #2077) then always
# took its fallback — the entry with root "/opt/ai" and name "lxd", an
# upper bound — and read the box as the disk owner, so disk_pct_gt still
# fired and disk-pressure.sh pruned Docker against space the box cannot
# free. The fix: the systemd unit and machine-sense.sh default to
# MACHINE_SENSE_FOLDER_ROOTS="/opt/ai /opt/ai/lxd/containers", and
# machine/README.md documents the requirement.
#
#   AC1  the systemd unit, machine-sense.sh and machine/install.sh carry the
#        deep default roots; README documents them
#   AC2  disk_owner_line's fallback is exercised: when folders[] holds only
#        the direct children of /opt/ai, the owner line is emitted from the
#        root "/opt/ai" + name "lxd" entry
#   AC3  machine-sense.sh run with the deep roots puts the box footprint in
#        folders[], and disk_owner_line then reads the box entry instead of
#        the upper bound
#
# Hermetic: stub readers (df, vgs, lxc, ps, nproc, du) on PATH and fixture
# machine.json files via MACHINE_REPORT. No network, no root, no LXD.
# Run via: tools/run-acceptance.sh 2094
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk date mktemp

UNIT="$REPO_ROOT/machine/disinto-machine-sense.service"
SENSE="$REPO_ROOT/machine/machine-sense.sh"
INSTALL="$REPO_ROOT/machine/install.sh"
README="$REPO_ROOT/machine/README.md"
PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"

DEEP_ROOTS="/opt/ai /opt/ai/lxd/containers"

# ── AC1: the deep default roots are wired into the unit and the script ───────
ac_log 'AC1: the systemd unit and machine-sense.sh default to the deep roots'
ac_assert_file "$UNIT" "machine/disinto-machine-sense.service must exist"
grep -qF "Environment=\"MACHINE_SENSE_FOLDER_ROOTS=$DEEP_ROOTS\"" "$UNIT" \
  || ac_fail "the systemd unit must set MACHINE_SENSE_FOLDER_ROOTS=\"$DEEP_ROOTS\" by default"
grep -qF "MACHINE_SENSE_FOLDER_ROOTS:-$DEEP_ROOTS" "$SENSE" \
  || ac_fail "machine-sense.sh must default MACHINE_SENSE_FOLDER_ROOTS to \"$DEEP_ROOTS\""
grep -qF 'MACHINE_SENSE_FOLDER_ROOTS' "$INSTALL" \
  || ac_fail "machine/install.sh must mention the MACHINE_SENSE_FOLDER_ROOTS default"

ac_log 'AC2: machine/README.md documents the deep-root requirement'
grep -qF '/opt/ai/lxd/containers' "$README" \
  || ac_fail "machine/README.md must name the deeper root /opt/ai/lxd/containers"
grep -qF 'MACHINE_SENSE_FOLDER_ROOTS' "$README" \
  || ac_fail "machine/README.md must document MACHINE_SENSE_FOLDER_ROOTS"

# ── AC3: disk_owner_line — the /opt/ai + lxd upper-bound fallback ────────────
ac_log 'AC3: the lxd upper-bound fallback emits the owner line from its entry'
FN_OWNER="$(ac_extract_fn disk_owner_line "$PREFLIGHT")"
[ -n "$FN_OWNER" ] || ac_fail "could not extract disk_owner_line() from supervisor/preflight.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now_epoch="$(date -u +%s)"

# machine.json fixture: $1 = folders JSON, $2 = volume mount, $3 = used_b
make_report() {
  jq -n --arg t "$(iso "$now_epoch")" --argjson folders "$1" \
      --arg mount "$2" --argjson used "$3" '
    {schema: 1, t: $t, errors: [],
     volumes: [
       {source: "/dev/sda1", fstype: "ext4", mount: $mount,
        size_b: 968000000000, used_b: $used, avail_b: 181000000000,
        used_pct: 81}
     ],
     folders: $folders}'
}

run_owner() {  # $1 = machine report path; echoes the Disk owner line
  MACHINE_REPORT="$1" OWNER_FN="$FN_OWNER" bash -c '
    set -u
    eval "$OWNER_FN"
    disk_owner_line
  '
}

# The live host layout before #2094: folders[] holds only direct children of
# /opt/ai. The box footprint is absent, so the owner line must come from the
# root "/opt/ai" + name "lxd" fallback entry (700 GB, not the 87 GB research
# entry).
make_report '[
  {"root": "/opt/ai", "name": "lxd", "size_b": 700000000000, "growth_b_per_day": 0},
  {"root": "/opt/ai", "name": "research", "size_b": 87000000000, "growth_b_per_day": 4000000000}
]' "/opt/ai" 787000000000 > "$WORK/live-layout.json"
out="$(run_owner "$WORK/live-layout.json")"
ac_assert_eq "$out" \
  "Disk owner: box (box 700 GB = 88% of used on /opt/ai, growth 0 GB/day)" \
  "AC3: the upper-bound fallback must emit the owner line from the lxd entry, got: $out"

# A small lxd entry through the same fallback reads neighbours: the fallback
# is an upper bound, not an automatic guilty verdict.
make_report '[
  {"root": "/opt/ai", "name": "lxd", "size_b": 36600000000, "growth_b_per_day": 0},
  {"root": "/opt/ai", "name": "research", "size_b": 700000000000, "growth_b_per_day": 0}
]' "/opt/ai" 787000000000 > "$WORK/fallback-small.json"
out="$(run_owner "$WORK/fallback-small.json")"
ac_assert_eq "$out" \
  "Disk owner: neighbours (box 36 GB = 4% of used on /opt/ai, growth 0 GB/day)" \
  "AC3: fallback entry of 4% of used must read neighbours, got: $out"

# With the deep default roots the box entry exists and wins over the upper
# bound: the 36.6 GB box folder, not the 700 GB lxd entry, drives the owner.
make_report '[
  {"root": "/opt/ai/lxd/containers", "name": "disinto-nomad-box", "size_b": 36600000000, "growth_b_per_day": 0},
  {"root": "/opt/ai/lxd/containers", "name": "other-box", "size_b": 300000000000, "growth_b_per_day": 0},
  {"root": "/opt/ai", "name": "lxd", "size_b": 700000000000, "growth_b_per_day": 0}
]' "/opt/ai" 787000000000 > "$WORK/deep.json"
out="$(run_owner "$WORK/deep.json")"
ac_assert_eq "$out" \
  "Disk owner: neighbours (box 36 GB = 4% of used on /opt/ai, growth 0 GB/day)" \
  "AC3: the named box entry must beat the lxd upper bound, got: $out"

# ── AC4: machine-sense.sh run with the deep roots lands the box footprint ────
ac_log 'AC4: machine-sense.sh with the deep roots emits the box entry into folders[]'
T="$WORK/sense"
STUB="$T/bin"
FAI="$T/ai"
mkdir -p "$STUB" "$T/proc" "$FAI/research" "$FAI/lxd/containers/disinto-nomad-box" \
         "$FAI/lxd/containers/other-box"

stub() {
  { printf '#!/usr/bin/env bash\n'; cat; } > "$STUB/$1"
  chmod +x "$STUB/$1"
}

stub df <<EOF
printf 'Filesystem Type Mounted 1B-blocks Used Avail\n'
printf '/dev/sda1 ext4 %s 968000000000 787000000000 181000000000\n' "$FAI"
EOF
stub vgs <<'EOF'
printf '  vg\t2000\t630\n'
EOF
stub lxc <<'EOF'
echo '[]'
EOF
stub ps <<'EOF'
printf '%s\n' '29442760 strata-host' '15962112 python'
EOF
stub nproc <<'EOF'
echo 4
EOF
stub du <<EOF
root="\${*: -1}"
case "\$root" in
  "$FAI") printf '%s\t%s\n' 800000000000 "\$root/lxd" 210000000000 "\$root/research" 1010000000000 "\$root" ;;
  "$FAI/lxd/containers") printf '%s\t%s\n' 36600000000 "\$root/disinto-nomad-box" 300000000000 "\$root/other-box" 336600000000 "\$root" ;;
  *) printf '%s\t%s\n' 0 "\$root" ;;
esac
EOF

printf '%s\n' 'MemTotal:       65000000 kB' 'MemAvailable:   14000000 kB' \
  'SwapTotal:       8000000 kB' 'SwapFree:        6000000 kB' \
  > "$T/proc/meminfo"
printf '1.20 1.10 1.05 3/100 42\n' > "$T/proc/loadavg"

REPORT="$T/share/machine.json"
rc=0
PATH="$STUB:$PATH" MACHINE_SENSE_SHARE="$T/share" MACHINE_SENSE_STATE="$T/state" \
  MACHINE_SENSE_PROC="$T/proc" MACHINE_SENSE_NEIGHBOURS="$T/neighbours.tsv" \
  MACHINE_SENSE_NOW="$now_epoch" \
  MACHINE_SENSE_FOLDER_ROOTS="$FAI $FAI/lxd/containers" \
  bash "$SENSE" || rc=$?
ac_assert_eq "$rc" "0" "AC4: machine-sense.sh must exit 0, got $rc"

ac_assert_eq "$(jq -c '.errors' "$REPORT")" "[]" \
  "AC4: every stubbed reader must succeed, errors: $(jq -c '.errors' "$REPORT")"

box_line="$(jq -r --arg r "$FAI/lxd/containers" \
  '.folders[] | select(.name == "disinto-nomad-box") | "\(.root) \(.size_b)"' "$REPORT")"
ac_assert_eq "$box_line" "$FAI/lxd/containers 36600000000" \
  "AC4: the box folder must appear in folders[] under the deep root, got: $box_line"

upper_line="$(jq -r --arg r "$FAI" \
  '.folders[] | select(.root == $r and .name == "lxd") | .size_b' "$REPORT")"
ac_assert_eq "$upper_line" "800000000000" \
  "AC4: the shallow root must still list its direct children, got: $upper_line"

# With the box footprint present, disk_owner_line reads the neighbours case —
# the situation #2077 was written to stop, now reachable without hand-edited
# host env because the unit installs the deep default roots.
out="$(run_owner "$REPORT")"
ac_assert_eq "$out" \
  "Disk owner: neighbours (box 36 GB = 4% of used on $FAI, growth 0 GB/day)" \
  "AC4: the deep-root report must read neighbours from the box entry, got: $out"

# ── AC5: syntax ──────────────────────────────────────────────────────────────
ac_log 'AC5: bash -n on machine-sense.sh and preflight.sh'
bash -n "$SENSE" || ac_fail "machine/machine-sense.sh must parse with bash -n"
bash -n "$PREFLIGHT" || ac_fail "supervisor/preflight.sh must parse with bash -n"

echo PASS
