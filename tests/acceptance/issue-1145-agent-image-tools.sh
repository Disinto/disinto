#!/usr/bin/env bash
# =============================================================================
# tests/acceptance/issue-1145-agent-image-tools.sh
#
# Issue #1145: bats was missing from the agent image, so any bats-backed
# issue forced the agent to bootstrap the tool (downloading it from GitHub
# at session time) before it could do any work.
#
# The fix adds `bats` to the apt-get install in the agents Dockerfile,
# alongside the other tools the agent is assumed to have (jq, curl, and the
# shell linter). Distro packages are version-pinned by the debian:bookworm
# base image, so nothing is curled from GitHub at build time.
#
# Extended by #1172: zstd (apt) and the dsh npm global (@deepseek-ai/dsh)
# must also be present, so sessions stop bootstrapping them at runtime.
# Extended by #1107: the dsh headless profile must be seeded into the image.
#
# This test is read-only: it greps the agents Dockerfile for the tool
# installs the agent is assumed to have and fails if any is missing.
# It builds nothing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/tests/lib/acceptance-helpers.sh"

ac_require_cmd awk grep

DOCKERFILE="$REPO_ROOT/docker/agents/Dockerfile"
ac_assert_file "$DOCKERFILE" "docker/agents/Dockerfile must exist"

# ── Base image: distro package versions are pinned by the Debian release ────
ac_log "checking the agents image is based on a Debian distro"
if ! head -1 "$DOCKERFILE" | grep -Eq '^FROM[[:space:]]+debian:'; then
  ac_fail "docker/agents/Dockerfile does not start from a debian: base image"
fi

# Extract the apt-get install package list: the line containing
# `apt-get install` plus its backslash-continued lines (package names are
# space-separated words; the pip3 follow-up on the same statement is harmless
# because we match whole words for the tools below).
APT_PACKAGES="$(awk '
  /apt-get install/ { in_install = 1 }
  in_install { print }
  in_install && !/\\$/ { in_install = 0 }
' "$DOCKERFILE")"

if [ -z "$APT_PACKAGES" ]; then
  ac_fail "no apt-get install statement found in docker/agents/Dockerfile"
fi

# ── Every tool the agent is assumed to have is a distro package ────────────
for tool in jq curl shellcheck bats zstd; do
  ac_log "checking the agents image installs $tool from the distro package"
  if ! printf '%s\n' "$APT_PACKAGES" | grep -qw "$tool"; then
    ac_fail "agent Dockerfile does not install $tool via apt-get"
  fi
done

# ── dsh is installed at build time as a pinned npm global ──────────────────
# Like the claude-code install above it, the version is pinned exactly so the
# image contents are reproducible; nothing is fetched at session start.
ac_log "checking the agents image installs the dsh npm global with a pinned version"
if ! grep -Eq '^RUN npm install -g @deepseek-ai/dsh@[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' "$DOCKERFILE"; then
  ac_fail "agent Dockerfile does not install @deepseek-ai/dsh as a pinned npm global"
fi

# ── the dsh headless profile is seeded at build time (#1107) ───────────────
# Hired dsh agents (--harness dsh) run `dsh --profile headless`; the profile
# must exist in the image so sessions never bootstrap it at runtime.
ac_log "checking the agents image seeds the dsh headless profile"
if ! grep -q '/opt/dsh/profiles/headless.json' "$DOCKERFILE"; then
  ac_fail "agent Dockerfile does not seed the dsh headless profile"
fi

ac_pass
