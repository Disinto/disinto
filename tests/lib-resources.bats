#!/usr/bin/env bats
# tests/lib-resources.bats — structured RESOURCES.md host blocks (#1304)
#
# lib/resources.sh: resources_hosts / resources_field / resources_pick parse
# `### <alias>` host blocks (class, ssh, cap, image) and pick the first
# host whose class matches and in-flight count is below cap — first fit
# only, no placement policy.

load '../lib/resources.sh'

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  # F — host inventory with NO `## llama` section (files without the
  # section are valid; see #1320).
  F="${BATS_TEST_TMPDIR}/RESOURCES.md"
  cat > "$F" <<'EOF'
# RESOURCES.md — test inventory

## Compute

### alpha
- class: cpu
- ssh: dev@alpha.example.com
- cap: 2
- image: ghcr.io/me/edge:local
- **Specs**: 8 GB RAM, 4 vCPU

### beta
- class: cpu
- ssh: dev@beta.example.com
- cap: 1

### gamma
- class: gpu
- ssh: dev@gamma.example.com
- cap: 1 concurrent

### prose-only
- **Specs**: no structured fields — must not be listed

## Domains

| Domain | Status |
|--------|--------|
| example.com | active |
EOF

  # L — same inventory plus a `## llama` lease section (#1320): 4 slots,
  # nomad-box holds 2, selenocyte-box holds 1 → 1 free.
  L="${BATS_TEST_TMPDIR}/RESOURCES-llama.md"
  cat > "$L" <<'EOF'
# RESOURCES.md — test inventory with a llama lease

## Compute

### alpha
- class: cpu
- ssh: dev@alpha.example.com
- cap: 2

## llama
- slots: 4
- holder: nomad-box 2
- holder: selenocyte-box 1
EOF
}

@test "resources_hosts lists class blocks in file order and skips prose blocks" {
  run resources_hosts "$F"
  [ "$status" -eq 0 ]
  [ "$output" = $'alpha\nbeta\ngamma' ]
}

@test "resources_field returns each field value" {
  [ "$(resources_field "$F" alpha class)" = "cpu" ]
  [ "$(resources_field "$F" alpha ssh)" = "dev@alpha.example.com" ]
  [ "$(resources_field "$F" alpha cap)" = "2" ]
  [ "$(resources_field "$F" alpha image)" = "ghcr.io/me/edge:local" ]
  [ "$(resources_field "$F" gamma cap)" = "1 concurrent" ]
}

@test "optional image absent is empty output (rc 0)" {
  local v
  v="$(resources_field "$F" beta image)"
  [ -z "$v" ]
}

@test "unknown field and missing args are usage errors (rc 2)" {
  local rc=0
  resources_field "$F" alpha notes || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  resources_hosts || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  resources_field "$F" alpha || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  resources_pick "$F" || rc=$?
  [ "$rc" -eq 2 ]
}

@test "resources_pick picks the first matching class with free capacity" {
  [ "$(resources_pick "$F" cpu)" = "alpha" ]
  [ "$(resources_pick "$F" cpu "0 0")" = "alpha" ]
  [ "$(resources_pick "$F" gpu)" = "gamma" ]
}

@test "one host at full cap is skipped; the next free host is picked" {
  # alpha (cap 2) at 2 in flight, beta (cap 1) free
  [ "$(resources_pick "$F" cpu "2 0")" = "beta" ]
  # two cpu hosts, cap 1, the first at cap
  local two="${BATS_TEST_TMPDIR}/two.md"
  cat > "$two" <<'EOF'
### one
- class: cpu
- ssh: dev@one.example.com
- cap: 1

### two
- class: cpu
- ssh: dev@two.example.com
- cap: 1
EOF
  [ "$(resources_pick "$two" cpu "1 0")" = "two" ]
}

@test "all matching hosts full is a non-zero exit" {
  local rc=0
  resources_pick "$F" cpu "2 2" || rc=$?
  [ "$rc" -eq 1 ]
}

@test "no matching class is a non-zero exit" {
  local rc=0
  resources_pick "$F" meep || rc=$?
  [ "$rc" -eq 1 ]
}

@test "counts shorter than the host list default to 0" {
  # only alpha's count given; beta defaults to 0 in flight
  [ "$(resources_pick "$F" cpu "2")" = "beta" ]
}

@test "counts align with resources_hosts order across classes, not the matching subsequence" {
  # Slot order is alpha, beta, gamma (all class-bearing blocks, file
  # order) — so gamma (cap 1) sits at slot 3, not slot 1. "0 0 3" must
  # NOT pick gamma (3 in flight vs cap 1), and "0 0 0" must.
  local rc=0
  resources_pick "$F" gpu "0 0 3" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(resources_pick "$F" gpu "0 0 0")" = "gamma" ]
  # cpu picks still read their own slots (1, 2), unaffected by slot 3
  [ "$(resources_pick "$F" cpu "0 0 3")" = "alpha" ]
}

@test "missing file is a non-zero exit for all three functions" {
  local missing="${BATS_TEST_TMPDIR}/nope.md" rc=0
  resources_hosts "$missing" || rc=$?
  [ "$rc" -eq 1 ]
  rc=0
  resources_field "$missing" alpha class || rc=$?
  [ "$rc" -eq 1 ]
  rc=0
  resources_pick "$missing" cpu || rc=$?
  [ "$rc" -eq 1 ]
}

@test "unknown alias is a non-zero exit" {
  local rc=0
  resources_field "$F" zeta class || rc=$?
  [ "$rc" -eq 1 ]
}

# ── llama slot lease (#1320) ─────────────────────────────────────────────────

@test "llama: slots/held/free on a leased section" {
  [ "$(resources_llama_slots "$L")" = "4" ]
  [ "$(resources_llama_held "$L")" = "3" ]
  [ "$(resources_llama_free "$L")" = "1" ]
}

@test "llama: example file — free equals slots minus held" {
  local slots held free
  slots="$(resources_llama_slots "$REPO_ROOT/RESOURCES.example.md")"
  held="$(resources_llama_held "$REPO_ROOT/RESOURCES.example.md")"
  free="$(resources_llama_free "$REPO_ROOT/RESOURCES.example.md")"
  [ "$slots" -ge 0 ] && [ "$held" -ge 0 ]
  [ "$free" -eq $((slots - held)) ]
}

@test "llama: no section — slots/free exit 1, held is 0, pick still works" {
  local rc=0
  resources_llama_slots "$F" || rc=$?
  [ "$rc" -eq 1 ]
  rc=0
  resources_llama_free "$F" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(resources_llama_held "$F")" = "0" ]
  # the host functions are unaffected by the absence of the section
  [ "$(resources_hosts "$F")" = $'alpha\nbeta\ngamma' ]
  [ "$(resources_pick "$F" cpu)" = "alpha" ]
}

@test "llama: a '## llama' section does not break host parsing" {
  [ "$(resources_hosts "$L")" = "alpha" ]
  [ "$(resources_pick "$L" cpu)" = "alpha" ]
  [ "$(resources_field "$L" alpha class)" = "cpu" ]
}

@test "llama: no holder lines — held 0, free equals slots" {
  local l2="${BATS_TEST_TMPDIR}/noholders.md"
  cat > "$l2" <<'EOF'
## llama
- slots: 2
EOF
  [ "$(resources_llama_slots "$l2")" = "2" ]
  [ "$(resources_llama_held "$l2")" = "0" ]
  [ "$(resources_llama_free "$l2")" = "2" ]
}

@test "llama: a non-integer holder count is a hard error for all three functions" {
  local l2="${BATS_TEST_TMPDIR}/badholder.md" rc=0 out
  cat > "$l2" <<'EOF'
## llama
- slots: 4
- holder: nomad-box two
EOF
  out="$(resources_llama_slots "$l2" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  rc=0
  out="$(resources_llama_held "$l2" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  rc=0
  out="$(resources_llama_free "$l2" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [ -z "$out" ]
  # the error goes to stderr
  [ -n "$(resources_llama_held "$l2" 2>&1 >/dev/null || true)" ]
}

@test "llama: a non-integer slots count is a hard error" {
  local l2="${BATS_TEST_TMPDIR}/badslots.md" rc=0
  cat > "$l2" <<'EOF'
## llama
- slots: 4 concurrent
EOF
  rc=0
  resources_llama_slots "$l2" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}

@test "llama: section inside a fenced code block is not the lease" {
  local l2="${BATS_TEST_TMPDIR}/fenced.md" rc=0
  cat > "$l2" <<'EOF'
## Compute

### alpha
- class: cpu
- ssh: dev@alpha.example.com
- cap: 1

## Notes

```
## llama
- slots: 9
```
EOF
  resources_llama_slots "$l2" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$(resources_pick "$l2" cpu)" = "alpha" ]
}

@test "llama: missing file is a non-zero exit for all three functions" {
  local missing="${BATS_TEST_TMPDIR}/nope.md" rc=0
  resources_llama_slots "$missing" || rc=$?
  [ "$rc" -eq 1 ]
  rc=0
  resources_llama_held "$missing" || rc=$?
  [ "$rc" -eq 1 ]
  rc=0
  resources_llama_free "$missing" || rc=$?
  [ "$rc" -eq 1 ]
}

@test "llama: missing args are usage errors (rc 2)" {
  local rc=0
  resources_llama_slots || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  resources_llama_held || rc=$?
  [ "$rc" -eq 2 ]
  rc=0
  resources_llama_free || rc=$?
  [ "$rc" -eq 2 ]
}
