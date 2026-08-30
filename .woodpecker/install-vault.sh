#!/usr/bin/env bash
# .woodpecker/install-vault.sh — install the Vault binary for the bats step.
#
# Vault is NOT packaged for Alpine (absent from main/community/edge), so it
# is installed from the official HashiCorp static build — a pure-Go binary
# with no glibc/musl runtime deps (unlike Nomad 1.8+, which needs glibc).
# Version tracks the VAULT_VERSION pin in lib/init/nomad/install.sh.
#
# This logic lives in a script, not an inline ci.yml command block, because
# Woodpecker pre-expands ${VAR} references in pipeline YAML against the
# pipeline environment before the command runs: shell-local variables
# (VAULT_VERSION, varch) are undefined there and expanded to empty, which
# mangled the download URL (vault//vault__linux_.zip → 404) in #1146.

set -euo pipefail

VAULT_VERSION=1.18.5

arch="$(apk --print-arch)"
case "$arch" in
  x86_64)  varch=amd64 ;;
  aarch64) varch=arm64 ;;
  *) echo "unsupported arch for vault: $arch" >&2; exit 1 ;;
esac

curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${varch}.zip" -o /tmp/vault.zip
unzip -o /tmp/vault.zip vault -d /usr/local/bin
chmod 0755 /usr/local/bin/vault
vault --version
