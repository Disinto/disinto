#!/usr/bin/env bash
# dsh-seed.sh — seed a DSH_HOME for one-shot dsh runs started outside
# docker/agents/entrypoint.sh (the vault runner, the reproduce sidecars).
#
# dsh_seed_home
#   Needs DSH_HOME and DSH_BASE_URL. Seed files come from
#   ${DSH_SEED_DIR:-/opt/dsh}. Writes only the files that are missing:
#     $DSH_HOME/profiles/headless.json  copy of the seed profile
#     $DSH_HOME/settings.yaml           settings-<DSH_PROVIDER>.yaml (default
#       llamacpp, #2004), __DSH_BASE_URL__ replaced
#   A DSH_PROVIDER that is not a plain [a-z0-9-] name, or whose template is
#   missing, warns on stderr and seeds no settings.yaml — no silent llamacpp
#   fallback (#2009). Mirrors the provider lookup in docker/agents/entrypoint.sh.
#   Returns 1 and writes nothing when DSH_HOME or DSH_BASE_URL is empty.
dsh_seed_home() {
  local seed="${DSH_SEED_DIR:-/opt/dsh}"
  local provider="${DSH_PROVIDER:-llamacpp}"
  if [ -z "${DSH_HOME:-}" ] || [ -z "${DSH_BASE_URL:-}" ]; then
    return 1
  fi
  if [ ! -f "$DSH_HOME/profiles/headless.json" ]; then
    mkdir -p "$DSH_HOME/profiles"
    cp "$seed/profiles/headless.json" "$DSH_HOME/profiles/headless.json"
  fi
  if [ ! -f "$DSH_HOME/settings.yaml" ]; then
    if [[ "$provider" =~ ^[a-z0-9-]+$ ]] \
      && [ -f "$seed/settings-$provider.yaml" ]; then
      mkdir -p "$DSH_HOME"
      sed "s|__DSH_BASE_URL__|${DSH_BASE_URL}|" \
        "$seed/settings-$provider.yaml" > "$DSH_HOME/settings.yaml"
    else
      echo "WARN: DSH_PROVIDER='$provider' is not a valid provider name or has no settings-$provider.yaml template in $seed; not seeding $DSH_HOME/settings.yaml" >&2
    fi
  fi
}
