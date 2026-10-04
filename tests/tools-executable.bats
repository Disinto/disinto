#!/usr/bin/env bats
# tests/tools-executable.bats — every tools/*.sh must be executable.
#
# The gardener (and other organs) invoke tools/*.sh directly, e.g.
#   "$FACTORY_ROOT/tools/sprint-outcomes.sh"   (gardener/gardener-run.sh)
# and the same for the claim/grade/calibration tools. A file committed at
# 100644 checks out non-executable, so the invocation fails with
# "Permission denied" (rc=126) — exactly what the 2026-10-04 13:11 gardener
# run hit for sprint-outcomes.sh (#1748).
#
# The per-issue acceptance test (tests/acceptance/issue-1748.sh) pins the
# git-recorded mode of tools/sprint-outcomes.sh to 100755. This suite is the
# broader guard: it fails CI the moment any future tools/*.sh lands without
# the exec bit, so the fix is a one-line chmod, not a content change.
#
# On failure it lists the non-executable tools so the reporter can `chmod +x`
# them and stage (or `git update-index --chmod=+x`).

@test "every tools/*.sh is executable" {
  local tools_dir f non_executable name

  tools_dir="$BATS_TEST_DIRNAME/../tools"

  non_executable=()
  for f in "$tools_dir"/*.sh; do
    # A directory (tools/edge-control) or a glob that matched nothing is
    # not a .sh file; skip it rather than misreporting a failure.
    [ -e "$f" ] || continue
    if [ ! -x "$f" ]; then
      name="${f##*/}"
      non_executable+=("$name")
    fi
  done

  if [ "${#non_executable[@]}" -gt 0 ]; then
    echo "non-executable tools/*.sh (the exec bit is required, #1748):"
    for name in "${non_executable[@]}"; do
      echo "  $name"
    done
    return 1
  fi

  return 0
}
