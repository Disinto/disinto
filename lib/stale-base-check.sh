#!/usr/bin/env bash
# stale-base-check.sh — Detect PRs whose merged result will silently revert
# upstream changes that landed on main since the PR's base.
#
# Background (#896):
#   PR #855 was based on a stale main. Between its author date and merge, two
#   unrelated PRs landed on main and modified docker/agents/entrypoint.sh and
#   dev/dev-poll.sh. PR #855's merge resolution kept its base versions of those
#   files, silently reverting both upstream changes. Review-bot APPROVED because
#   the forward diff (head vs base) was correct — it never compared head vs
#   current main HEAD.
#
# Approach:
#   For each file modified upstream since the PR's merge-base, check whether
#   the PR-head version contains the lines upstream added. Lines added by
#   upstream that are missing from PR-head are candidates for silent revert.
#   We flag a file only when most upstream-added lines are absent (default
#   >=50%) — a PR that legitimately edits some of those lines will replace
#   them rather than drop them all, keeping the missing-fraction low.
#
# Public API (after sourcing):
#   stale_base_check <pr_head_ref> <main_ref> [threshold_pct]
#       Echoes one line per flagged file:
#           <file>|missing=<N>|total=<M>|pct=<P>
#       where <N>/<M> count meaningful (non-blank) upstream-added lines
#       missing from the PR-head version, and <P> is the percentage.
#       Returns 0 always (errors are non-fatal — silent skip on bad refs).
#
#   stale_base_check_format <output>
#       Pretty-prints the structured output of stale_base_check as a
#       markdown bullet list. Echoes nothing for empty input.
#
# Operates on the current git repository (cwd or $GIT_DIR). The caller is
# responsible for ensuring relevant refs are fetched.

# stale_base_check PR_HEAD MAIN_REF [THRESHOLD_PCT]
stale_base_check() {
  local pr_head="$1"
  local main_ref="$2"
  local threshold="${3:-50}"

  [ -z "$pr_head" ] || [ -z "$main_ref" ] && return 0

  local merge_base
  merge_base=$(git merge-base "$pr_head" "$main_ref" 2>/dev/null) || return 0
  [ -z "$merge_base" ] && return 0

  # Files modified upstream since merge-base
  local upstream_files
  upstream_files=$(git diff --name-only "$merge_base" "$main_ref" 2>/dev/null) || return 0
  [ -z "$upstream_files" ] && return 0

  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue

    # Skip files the PR doesn't touch — a clean 3-way merge keeps main's
    # version, so no revert is possible.
    if git diff --quiet "$merge_base" "$pr_head" -- "$f" 2>/dev/null; then
      continue
    fi

    # Skip if PR deleted the file outright (intentional removal, not a
    # silent revert — reviewer will see the deletion in the diff).
    if ! git cat-file -e "${pr_head}:${f}" 2>/dev/null; then
      continue
    fi

    # Pull the three versions
    local base_content main_content pr_content
    base_content=$(git show "${merge_base}:${f}" 2>/dev/null || printf '')
    main_content=$(git show "${main_ref}:${f}" 2>/dev/null || printf '')
    pr_content=$(git show "${pr_head}:${f}" 2>/dev/null || printf '')

    # Lines added upstream (present in main, absent in merge-base).
    # Use process substitution + diff with `>` markers (lines unique to
    # the second file). This is line-granular and stable.
    local upstream_added
    upstream_added=$(diff <(printf '%s\n' "$base_content") <(printf '%s\n' "$main_content") \
      | sed -n 's/^> //p')
    [ -z "$upstream_added" ] && continue

    # Count meaningful (non-blank) upstream-added lines missing from PR head.
    local total=0 missing=0 line stripped
    while IFS= read -r line; do
      stripped=$(printf '%s' "$line" | tr -d '[:space:]')
      [ -z "$stripped" ] && continue
      total=$((total + 1))
      if ! grep -qFx -- "$line" <<<"$pr_content"; then
        missing=$((missing + 1))
      fi
    done <<<"$upstream_added"

    [ "$total" -eq 0 ] && continue
    [ "$missing" -eq 0 ] && continue

    local pct=$((missing * 100 / total))
    if [ "$pct" -ge "$threshold" ]; then
      printf '%s|missing=%d|total=%d|pct=%d\n' "$f" "$missing" "$total" "$pct"
    fi
  done <<<"$upstream_files"

  return 0
}

# stale_base_check_format STRUCTURED_OUTPUT
# Convert the pipe-delimited output of stale_base_check into a markdown
# bullet list suitable for embedding in a review prompt or PR comment.
stale_base_check_format() {
  local input="$1"
  [ -z "$input" ] && return 0
  local line file rest
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    file="${line%%|*}"
    rest="${line#*|}"
    printf -- '- `%s` — %s\n' "$file" "$rest"
  done <<<"$input"
}
