#!/usr/bin/env bash
# dsh-seed.sh — seed a DSH_HOME for one-shot dsh runs started outside
# docker/agents/entrypoint.sh (the vault runner, the reproduce sidecars).
#
# dsh_seed_home
#   Needs DSH_HOME and DSH_BASE_URL. Seed files come from
#   ${DSH_SEED_DIR:-/opt/dsh}. Writes only the files that are missing:
#     $DSH_HOME/profiles/headless.json  copy of the seed profile
#     $DSH_HOME/settings.yaml           settings-llamacpp.yaml, __DSH_BASE_URL__ replaced
#   Returns 1 and writes nothing when DSH_HOME or DSH_BASE_URL is empty.
dsh_seed_home() {
  local seed="${DSH_SEED_DIR:-/opt/dsh}"
  if [ -z "${DSH_HOME:-}" ] || [ -z "${DSH_BASE_URL:-}" ]; then
    return 1
  fi
  if [ ! -f "$DSH_HOME/profiles/headless.json" ]; then
    mkdir -p "$DSH_HOME/profiles"
    cp "$seed/profiles/headless.json" "$DSH_HOME/profiles/headless.json"
  fi
  if [ ! -f "$DSH_HOME/settings.yaml" ]; then
    mkdir -p "$DSH_HOME"
    sed "s|__DSH_BASE_URL__|${DSH_BASE_URL}|" \
      "$seed/settings-llamacpp.yaml" > "$DSH_HOME/settings.yaml"
  fi
}
