#!/usr/bin/env bash
# project-checkout.sh — the sidecar's own clean clone of the project.
#
# sidecar_project_checkout
#   Clones ${FORGE_URL}/${FORGE_REPO}.git into $PROJECT_REPO_ROOT on first use;
#   later runs fetch and reset it to origin/$PRIMARY_BRANCH, so a previous
#   triage's debug branch or edits never leak into the next run. The token goes
#   in a per-command http.extraHeader and is never written to .git/config.
#   Returns non-zero when git fails.
sidecar_project_checkout() {
  local -a auth=(-c "http.extraHeader=Authorization: token ${FORGE_TOKEN:-}")
  if [ ! -d "$PROJECT_REPO_ROOT/.git" ]; then
    git "${auth[@]}" clone --branch "$PRIMARY_BRANCH" \
      "${FORGE_URL}/${FORGE_REPO}.git" "$PROJECT_REPO_ROOT"
    return
  fi
  git "${auth[@]}" -C "$PROJECT_REPO_ROOT" fetch origin "$PRIMARY_BRANCH" \
    && git -C "$PROJECT_REPO_ROOT" checkout -f "$PRIMARY_BRANCH" \
    && git -C "$PROJECT_REPO_ROOT" reset --hard "origin/$PRIMARY_BRANCH" \
    && git -C "$PROJECT_REPO_ROOT" clean -fdq
}
