#!/usr/bin/env bash
# =============================================================================
# lib/sprint-milestone.sh — the project-repo milestone of a pitch's sprint
#
# A sprint is a Forgejo milestone on the project repo. Its description is the
# purpose paragraph, a blank line, the sprint block, a blank line and the
# marker line `<!-- pitch: sprints/<slug>.md -->`; the first milestones were
# written that way by hand. Nothing created one from a pitch: lib/sprint-filer.sh
# files sub-issues, but it neither creates a milestone nor sets one.
#
# #1889, step 3 of 6 in "a pitch becomes a sprint": when the owner merges the
# ops-repo PR that adds sprints/<slug>.md, this step creates that milestone
# exactly once on the project repo (the other steps file sub-issues into it
# and record the tape proposal). The marker line lets the function find the
# milestone again on a second call, and the marker being an HTML comment keeps
# the description readable by the readers that call sprint_field on it (dev-poll's
# emit_tape_proposal, tools/sprint-outcomes.sh).
#
# Function (sourced; no callers yet — #1892 wires it up):
#   sprint_milestone_ensure FILE
#     -> the id of FILE's milestone. When no listed milestone already carries
#        the marker `<!-- pitch: sprints/<slug>.md -->` in its description,
#        the milestone is created with FORGE_FILER_TOKEN via POST
#        ${FORGE_API}/milestones and its id printed; when one carries it, the
#        existing id is printed and nothing is created.
#       * Title: the first `# ` line of FILE with `# ` and a leading
#         `Sprint: ` stripped; when no such line exists, the slug (FILE's
#         basename minus `.md`).
#       * Description: the pitch's purpose paragraph (pitch_purpose), a blank
#         line, the sprint block (pitch_sprint_block), a blank line and the
#         marker. When pitch_purpose returns 1 (no paragraph), the description
#         is the block, a blank line, the marker.
#       * The list is paged with limit=50, page 1, 2, ... until a page has
#         fewer than 50 milestones.
#       * Returns 1, prints nothing and creates nothing when FILE has no
#         valid sprint block (pitch_sprint_block fails), when a listing call
#         fails or a page is not a JSON array, or when the POST fails or
#         carries no `.id`.
#
# Notes:
#   * The lib only reads FILE and writes nothing on disk; its only writes are
#     the two forge calls (GET milestones list, POST milestones).
#   * The marker line is an HTML comment, so the readers that call
#     sprint_field on the milestone's description (dev-poll,
#     tools/sprint-outcomes.sh) are not affected by the marker's presence.
#
# Environment:
#   FORGE_API          — project-repo API base (e.g. https://forge.example/api/v1/repos/o/p)
#   FORGE_FILER_TOKEN  — filer-bot API token (issues:write on the project repo)
#
# Sourced from the caller:
#   source "$(dirname "$0")/lib/sprint-milestone.sh"
# =============================================================================
set -euo pipefail

# shellcheck source=pitch.sh
source "$(dirname "${BASH_SOURCE[0]}")/pitch.sh"

# _sprint_title FILE — the first line of FILE that starts with `# ` (a one-hash
# heading — `## ...` does not match, its second character is `#`, not a space),
# with `# ` and any leading `Sprint: ` stripped and whitespace trimmed. Prints
# nothing when no such line exists or the heading has nothing but whitespace.
_sprint_title() {
  local file="$1" line title
  while IFS= read -r line || [ -n "${line:-}" ]; do
    if [[ "$line" == '# '* ]]; then
      title="${line#'# '}"
      # Trim leading whitespace (double `#  Sprint:` -> ` Sprint: ...`).
      title="${title#"${title%%[![:space:]]*}"}"
      # Strip a leading `Sprint: ` so `# Sprint: Demo sprint` -> `Demo sprint`.
      title="${title#"Sprint: "}"
      title="${title#"${title%%[![:space:]]*}"}"
      if [ -n "$title" ]; then
        printf '%s\n' "$title"
      fi
      return 0
    fi
  done < "$file"
}

# sprint_milestone_ensure FILE — the milestone id of FILE's sprint; creates it
# exactly once. FILE is a pitch file (sprints/<slug>.md in the ops repo or
# a copy of one). Returns 1 (no output, no POST) when FILE has no valid sprint
# block or when a forge call fails; on success the id is printed.
sprint_milestone_ensure() {
  local file="${1:-}" slug marker title purpose block description
  local id page count body resp

  # No pitch file, no valid sprint block (missing markers, or no class line):
  # nothing to create — print nothing, no forge call.
  block="$(pitch_sprint_block "$file")" || return 1

  # Slug and marker: `basename FILE .md`, and the line that identifies this
  # pitch's milestone on re-read.
  slug="$(basename "$file" .md)"
  marker="<!-- pitch: sprints/${slug}.md -->"

  # Title: the first `# ` heading, stripped of `# ` and any leading
  # `Sprint: `; the slug when there is no such line.
  title="$(_sprint_title "$file")"
  [ -n "$title" ] || title="$slug"

  # Description: purpose paragraph (when present), blank line, block, blank
  # line, marker — the exact shape of the hand-written milestones 1-3.
  purpose="$(pitch_purpose "$file")" || purpose=""
  if [ -n "$purpose" ]; then
    description="$purpose"$'\n\n'"$block"$'\n\n'"$marker"
  else
    description="$block"$'\n\n'"$marker"
  fi

  # List milestones, paging 50 at a time (page 1, 2, ...) until a page has
  # fewer than 50 entries. A failed call or a page that is not a JSON array
  # creates nothing and returns 1.
  page=1
  while :; do
    body="$(curl -sf \
        -H "Authorization: token ${FORGE_FILER_TOKEN}" \
        "${FORGE_API}/milestones?state=all&limit=50&page=${page}")" || return 1
    if ! printf '%s\n' "$body" | jq -e 'type == "array"' >/dev/null 2>&1; then
      return 1
    fi

    id="$(printf '%s\n' "$body" | jq -r --arg marker "$marker" \
        '.[] | select((.description // "") | contains($marker))
          | .id | if type == "null" then empty else . end' \
      | head -n1)"
    if [ -n "$id" ]; then
      printf '%s\n' "$id"
      return 0
    fi

    count="$(printf '%s\n' "$body" | jq 'length')"
    if [ "$count" -ge 50 ]; then
      page=$((page + 1))
      continue
    fi
    break
  done

  # Not found: create it. The body is built with jq so arbitrary pitch text
  # is valid JSON; `-c` keeps it a single line for logging.
  body="$(jq -cn \
      --arg title "$title" \
      --arg description "$description" \
      '{title: $title, description: $description}')" || return 1
  resp="$(curl -sf -X POST \
      -H "Authorization: token ${FORGE_FILER_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "${FORGE_API}/milestones")" || return 1
  id="$(printf '%s\n' "$resp" | jq -r '.id' | head -n1)"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$id"
  return 0
}
