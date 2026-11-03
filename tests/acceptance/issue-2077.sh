#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-2077.sh
#
# Issue #2077: disk-pressure fires only when the box's own footprint is the
# pressure.
#
#   preflight.sh prints a "Disk owner: box|neighbours|unknown (<detail>)" line
#   in the System Resources section, computed in one jq pass over the machine
#   report ${MACHINE_REPORT:-/srv/disinto/machine/machine.json} (#2070).
#   Footprint: the folders[] entry named ${MACHINE_BOX_NAME:-disinto-nomad-box},
#   else the entry with root "/opt/ai" and name "lxd" (an upper bound). Volume:
#   the volumes[] entry whose mount is the longest prefix of the footprint's
#   root. share = floor(size_b * 100 / used_b), growth = growth_b_per_day // 0.
#   Owner is box when share >= ${DISK_OWNER_PCT:-20} or growth >=
#   ${DISK_OWNER_GROWTH_B:-5368709120} (5 GiB a day), else neighbours. unknown
#   — each with its reason in the detail — when: no file, not JSON, t more than
#   1800 s old, errors[] not empty, no footprint entry, no volume.
#
#   eval_disk_pct_gt returns 1 (the recipe does not fire) when the threshold
#   is met and the section carries "Disk owner: neighbours"; when it fires with
#   an owner line present, the owner text joins _EVIDENCE. unknown or a missing
#   owner line fires as before.
#
# Hermetic: fixture machine.json files via MACHINE_REPORT, no network.
# Run via: tools/run-acceptance.sh 2077
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/acceptance-helpers.sh
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd bash jq grep awk date mktemp

PREFLIGHT="$REPO_ROOT/supervisor/preflight.sh"
EVALUATOR="$REPO_ROOT/supervisor/evaluate-recipes.sh"
AGENTS_MD="$REPO_ROOT/supervisor/AGENTS.md"

for _pair in \
  "$PREFLIGHT|supervisor/preflight.sh must exist" \
  "$EVALUATOR|supervisor/evaluate-recipes.sh must exist" \
  "$AGENTS_MD|supervisor/AGENTS.md must exist"
do
  ac_assert_file "${_pair%%|*}" "${_pair#*|}"
done

# has_text TEXT NEEDLE — pure bash substring check (the #1650/#1687 lesson:
# `printf ... | grep -q X` can die with 141 under pipefail even when grep
# matched).
has_text() {
  local text="$1" needle="$2"
  [[ "${text//$'\r'}" == *"$needle"* ]]
}

# ── Static wiring ────────────────────────────────────────────────────────────
ac_log 'Static: disk_owner_line exists and runs right after the Disk echo line'
FN_OWNER="$(ac_extract_fn disk_owner_line "$PREFLIGHT")"
[ -n "$FN_OWNER" ] || ac_fail "could not extract disk_owner_line() from preflight.sh"
grep -qF 'disk_owner_line' "$PREFLIGHT" \
  || ac_fail "preflight.sh main block never calls disk_owner_line"
awk '
  /^echo "Disk: / { d = NR }
  /^disk_owner_line$/ { o = NR }
  END { if (!d || !o || o != d + 1) exit 1 }
' "$PREFLIGHT" \
  || ac_fail "disk_owner_line must be called directly after the Disk echo line"

grep -qF 'Disk owner:` (#2077): box, neighbours or unknown, from the machine' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md preflight entry must document the Disk owner line (#2077)"
# shellcheck disable=SC2016  # the backticks are literal prose from AGENTS.md
grep -qF 'disk_pct_gt` does not fire when the disk owner is `neighbours`' "$AGENTS_MD" \
  || ac_fail "supervisor/AGENTS.md must document that disk_pct_gt does not fire for neighbours"

# ── Fixtures ─────────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now_epoch="$(date -u +%s)"

# machine.json fixture: $1=size_b $2=growth_b_per_day $3=used_b $4=t_epoch
make_report() {
  jq -n --arg t "$(iso "$4")" --argjson size "$1" --argjson growth "$2" \
      --argjson used "$3" '
    {schema: 1, t: $t, errors: [],
     volumes: [
       {source: "/dev/sda1", fstype: "ext4", mount: "/opt/ai",
        size_b: 968000000000, used_b: $used, avail_b: 0, used_pct: 81},
       {source: "tmpfs", fstype: "tmpfs", mount: "/tmp",
        size_b: 1000000000, used_b: 100000000, avail_b: 900000000, used_pct: 10}
     ],
     folders: [
       {root: "/opt/ai/lxd/containers", name: "disinto-nomad-box", size_b: $size,
        measured: $t, growth_b_per_day: $growth},
       {root: "/opt/ai/lxd/containers", name: "other-project", size_b: 750000000000,
        measured: $t, growth_b_per_day: 2000000000},
       {root: "/opt/ai", name: "lxd", size_b: $used,
        measured: $t, growth_b_per_day: 0}
     ]}'
}

run_disk_owner() {  # $1 = MACHINE_REPORT path, optional env overrides inherit
  OWNER_FN="$FN_OWNER" bash -c '
    set -u
    eval "$OWNER_FN"
    disk_owner_line
  '
}

owner_line() {  # $1 = report path; echoes the printed line
  MACHINE_REPORT="$1" run_disk_owner
}

# ── AC1: neighbours when the box is 4% of a volume 81% used ─────────────────
ac_log 'AC1: box 36.6 GB of a 787 GB-used volume reads neighbours'
make_report 36600000000 0 787000000000 "$now_epoch" > "$WORK/neighbours.json"
out="$(owner_line "$WORK/neighbours.json")"
ac_assert_eq "$out" \
  "Disk owner: neighbours (box 36 GB = 4% of used on /opt/ai, growth 0 GB/day)" \
  "AC1: neighbours case, got: $out"

# ── AC2: growth 6e9 B/day and a 38% footprint both read box ──────────────────
ac_log 'AC2: growth >= 5 GiB/day, or share >= 20%, reads box'
make_report 36600000000 6000000000 787000000000 "$now_epoch" > "$WORK/growth.json"
out="$(owner_line "$WORK/growth.json")"
ac_assert_eq "$out" \
  "Disk owner: box (box 36 GB = 4% of used on /opt/ai, growth 6 GB/day)" \
  "AC2a: growth case, got: $out"

make_report 300000000000 0 787000000000 "$now_epoch" > "$WORK/big.json"
out="$(owner_line "$WORK/big.json")"
ac_assert_eq "$out" \
  "Disk owner: box (box 300 GB = 38% of used on /opt/ai, growth 0 GB/day)" \
  "AC2b: share case, got: $out"

# MACHINE_BOX_NAME picks the box's own folder when it is not the default name.
out="$(MACHINE_REPORT="$WORK/neighbours.json" MACHINE_BOX_NAME="other-project" OWNER_FN="$FN_OWNER" bash -c '
  set -u; eval "$OWNER_FN"; disk_owner_line
')"
ac_assert_eq "$out" \
  "Disk owner: box (box 750 GB = 95% of used on /opt/ai, growth 2 GB/day)" \
  "AC2c: MACHINE_BOX_NAME override must pick the named folder, got: $out"

# ── AC3: unknown cases, each naming its reason ───────────────────────────────
ac_log 'AC3: stale t, non-empty errors[], missing file, broken JSON read unknown'
make_report 36600000000 0 787000000000 "$((now_epoch - 7200))" > "$WORK/stale.json"
out="$(owner_line "$WORK/stale.json")"
has_text "$out" "Disk owner: unknown (" \
  || ac_fail "AC3a: stale report must read unknown, got: $out"
has_text "$out" "120 minutes old" \
  || ac_fail "AC3a: unknown reason must name the stale t, got: $out"

jq --argjson e '["folders:/opt/ai"]' '.errors = $e' "$WORK/neighbours.json" > "$WORK/errors.json"
out="$(owner_line "$WORK/errors.json")"
has_text "$out" "Disk owner: unknown (" \
  || ac_fail "AC3b: report with errors[] must read unknown, got: $out"
has_text "$out" "errors" \
  || ac_fail "AC3b: unknown reason must name the errors, got: $out"

out="$(owner_line "$WORK/does-not-exist.json")"
has_text "$out" "Disk owner: unknown (" \
  || ac_fail "AC3c: missing report file must read unknown, got: $out"
has_text "$out" "no machine report" \
  || ac_fail "AC3c: unknown reason must name the missing file, got: $out"

printf 'garbage {\n' > "$WORK/not-json.json"
out="$(owner_line "$WORK/not-json.json")"
has_text "$out" "Disk owner: unknown (" \
  || ac_fail "AC3d: non-JSON report must read unknown, got: $out"
has_text "$out" "not JSON" \
  || ac_fail "AC3d: unknown reason must name the broken JSON, got: $out"

# ── AC4: eval_disk_pct_gt does not fire when the owner is neighbours ─────────
ac_log 'AC4: eval_disk_pct_gt returns 1 with Disk owner: neighbours'
FN_EVAL="$(ac_extract_fn eval_disk_pct_gt "$EVALUATOR")"
[ -n "$FN_EVAL" ] || ac_fail "could not extract eval_disk_pct_gt() from evaluate-recipes.sh"

run_eval() {  # $1 = section text, $2 = threshold; echoes evidence on fire
  EVAL_FN="$FN_EVAL" EVAL_SECTION="$1" EVAL_THRESHOLD="$2" bash -c '
    set -u
    eval "$EVAL_FN"
    _EVIDENCE=""
    if eval_disk_pct_gt "$EVAL_SECTION" "$EVAL_THRESHOLD"; then
      printf "%s\n" "$_EVIDENCE"
      exit 0
    fi
    exit 1
  '
}

neigh_section='Disk: 85% used (500G/600G on /)
Disk owner: neighbours (box 36 GB = 4% of used on /opt/ai, growth 0 GB/day)'
if run_eval "$neigh_section" 80 >/dev/null; then
  ac_fail "AC4: disk_pct_gt must NOT fire when the disk owner is neighbours"
fi

# ── AC5: box, unknown, and no-owner-line all still fire ──────────────────────
ac_log 'AC5: owner box / unknown / no owner line fire, with owner text in evidence'
box_section='Disk: 85% used (500G/600G on /)
Disk owner: box (box 300 GB = 38% of used on /opt/ai, growth 0 GB/day)'
ev="$(run_eval "$box_section" 80)" || ac_fail "AC5: owner box must fire, got rc=1"
has_text "$ev" "box (box 300 GB = 38% of used on /opt/ai, growth 0 GB/day)" \
  || ac_fail "AC5: evidence must contain the owner text, got: $ev"

unk_section='Disk: 85% used (500G/600G on /)
Disk owner: unknown (no machine report at /srv/disinto/machine/machine.json)'
ev="$(run_eval "$unk_section" 80)" || ac_fail "AC5: owner unknown must fire, got rc=1"
has_text "$ev" "unknown (no machine report at /srv/disinto/machine/machine.json)" \
  || ac_fail "AC5: evidence must contain the owner text, got: $ev"

no_owner_section='Disk: 85% used (500G/600G on /)
Load: 0.12 0.09 0.08'
ev="$(run_eval "$no_owner_section" 80)" || ac_fail "AC5: no owner line must fire as today, got rc=1"
has_text "$ev" "Disk: 85% used" \
  || ac_fail "AC5: evidence must carry the disk line, got: $ev"
if has_text "$ev" "owner"; then
  ac_fail "AC5: evidence must not name an owner when there is none, got: $ev"
fi

# The rule still guards: below the threshold nothing fires, owner or not.
if run_eval "$neigh_section" 90 >/dev/null; then
  ac_fail "AC5: disk_pct_gt must not fire below the threshold"
fi

# ── AC6: syntax and the neighbouring regression test ─────────────────────────
ac_log 'AC6: bash -n on both files; issue-1713.sh still passes'
bash -n "$PREFLIGHT" || ac_fail "preflight.sh must parse with bash -n"
bash -n "$EVALUATOR" || ac_fail "evaluate-recipes.sh must parse with bash -n"
bash "$REPO_ROOT/tests/acceptance/issue-1713.sh" >/dev/null \
  || ac_fail "issue-1713.sh (recipe-eval gate) must still pass"

echo PASS
