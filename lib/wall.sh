#!/usr/bin/env bash
# =============================================================================
# lib/wall.sh — the wall: the forge's protected file patterns on `main` (#2120)
#
# docs/design/notes/self-update.md, "The wall": with rollouts the factory can
# change what grades it, what stops it and what gates it. The wall is the list
# of files the bots cannot change on `main` through their own merges: the bots
# have write, not admin, so a PR that touches a protected file waits for the
# owner, who merges it as `disinto-admin` (the API's force_merge). On the ops
# repo the wall also refuses a direct push that changes one of its files, while
# every other push stays open, exactly as today.
#
# This module does NOT source lib/env.sh: a repo admin runs it with FORGE_URL
# and FORGE_TOKEN in the environment, through lib/branch-rules.sh (#2110).
#
# Run directly (a deliberate step by a repo admin):
#   FORGE_URL=... FORGE_TOKEN=... lib/wall.sh apply disinto-admin/disinto disinto
#   FORGE_URL=... FORGE_TOKEN=... lib/wall.sh apply disinto-admin/ops ops
#
# Or source it and call:
#   wall_patterns KIND  — KIND's protected files, joined by ';'
#   wall_hits KIND      — paths on stdin (one per line) that are walled
#   wall_apply REPO KIND — set the patterns on main through branch_rule_apply
# =============================================================================
set -euo pipefail

# shellcheck source=branch-rules.sh
source "$(dirname "${BASH_SOURCE[0]}")/branch-rules.sh"

# The two lists, in the order of the table in the design note: what grades it,
# what stops it, what gates it, what rolls it out, the design. Keep this short:
# every entry means a PR waits for the owner.
_WALL_DISINTO='tools/sprint-grades.sh;tools/sprint-held.sh;tools/grade.sh;tools/grade-threshold.sh;lib/sprint-block.sh;lib/repair-suspend.sh;action-vault/policy.toml;tools/rollout.sh;.woodpecker/*.yml;docs/design/**'
_WALL_OPS='vault/policy.toml;packs/repair.toml;packs/rollout.toml'

# wall_patterns KIND — print KIND's list joined by ';'. KIND is disinto or
# ops; anything else returns 1 and prints nothing.
wall_patterns() {
  case "${1:-}" in
    disinto)
      printf '%s\n' "$_WALL_DISINTO"
      ;;
    ops)
      printf '%s\n' "$_WALL_OPS"
      ;;
    *)
      return 1
      ;;
  esac
}

# wall_hits KIND — read paths on stdin, one per line, and print those matching
# a pattern of KIND, in input order. Bash's [[ path == pattern ]] glob: '*'
# also matches '/'. An unknown KIND returns 1.
wall_hits() {
  local kind="${1:-}"
  local patterns
  patterns=$(wall_patterns "$kind") || return 1

  local -a pats
  IFS=';' read -r -a pats <<< "$patterns"

  local path pattern
  while IFS= read -r path; do
    for pattern in "${pats[@]}"; do
      # pattern stays unquoted on the right of ==: quoting it turns the glob
      # into a literal string comparison (issue #2120). SC2053 is therefore
      # deliberately disabled here.
      # shellcheck disable=SC2053
      if [[ "$path" == $pattern ]]; then
        printf '%s\n' "$path"
        break
      fi
    done
  done
  return 0
}

# wall_apply REPO KIND — put the wall on main of REPO through
# branch_rule_apply (lib/branch-rules.sh):
#   disinto: patch only protected_file_patterns on the existing main rule;
#   ops: a new rule that keeps direct pushes open to every writer (enable_push
#        true, as today) and refuses a change to the walled files.
# Returns branch_rule_apply's code.
wall_apply() {
  if [ "$#" -ne 2 ]; then
    printf 'wall: wall_apply needs REPO (owner/repo) and KIND (disinto|ops)\n' >&2
    return 2
  fi
  local repo="$1" kind="$2" patterns
  patterns=$(wall_patterns "$kind") || return 1

  local json
  case "$kind" in
    disinto)
      json="{\"protected_file_patterns\":\"$patterns\"}"
      ;;
    ops)
      json="{\"enable_push\":true,\"protected_file_patterns\":\"$patterns\"}"
      ;;
    *)
      return 1
      ;;
  esac

  branch_rule_apply "$repo" main "$json"
}

# -----------------------------------------------------------------------------
# CLI: run directly, not sourced.
# -----------------------------------------------------------------------------
_wall_usage() {
  cat >&2 <<'EOF'
Usage: lib/wall.sh apply <owner/repo> <disinto|ops>

  apply <owner/repo> <disinto|ops>   put the wall's protected file patterns
                                     on main of that repo

Requires FORGE_URL and FORGE_TOKEN in the environment (the token of a repo
admin, e.g. disinto-admin).
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  if [ "$cmd" = "apply" ]; then
    shift
    if [ "$#" -ne 2 ]; then
      _wall_usage
      exit 2
    fi
    wall_apply "$1" "$2"
    exit $?
  fi
  _wall_usage
  exit 2
fi
