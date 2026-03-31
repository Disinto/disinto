#!/usr/bin/env bash
# vault-env.sh — Shared vault environment: loads lib/env.sh and activates
# vault-bot's Forgejo identity (#747).
# Source this instead of lib/env.sh in vault scripts.

# shellcheck source=../lib/env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"
# Use vault-bot's own Forgejo identity
FORGE_TOKEN="${FORGE_VAULT_TOKEN:-${FORGE_TOKEN}}"

# Vault redesign in progress (PR-based approval workflow)
# This file is kept for shared env setup; scripts being replaced by #73
