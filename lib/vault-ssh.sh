#!/usr/bin/env bash
# =============================================================================
# lib/vault-ssh.sh — Vault-held SSH material for the ephemeral runner
#
# SSH private keys are file secrets, not env vars (newlines, process list).
# They live at kv/data/disinto/runner/SSH_KEY and SSH_KNOWN_HOSTS, rendered
# by Nomad into ${NOMAD_SECRETS_DIR}/ssh/ (or mounted there by the docker
# dispatcher) and installed into $HOME/.ssh by the runner entrypoint.
#
# Agents never see these — lib/env.sh unsets them, and only vault-runner
# templates/mounts the files (AD-006).
#
# Public:
#   vault_ssh_is_file_secret NAME
#   vault_ssh_relpath NAME          — path under /secrets/ (no leading slash)
#   vault_ssh_install [SECRETS_DIR] [HOME_DIR]
# =============================================================================

vault_ssh_is_file_secret() {
  case "$1" in
    SSH_KEY|SSH_KNOWN_HOSTS) return 0 ;;
    *) return 1 ;;
  esac
}

vault_ssh_relpath() {
  case "$1" in
    SSH_KEY)          printf 'ssh/id_ed25519\n' ;;
    SSH_KNOWN_HOSTS)  printf 'ssh/known_hosts\n' ;;
    *) return 1 ;;
  esac
}

# Copy vault-rendered SSH files into HOME/.ssh with ssh-required modes.
# No-op (0) when the key file is missing or empty — formulas that don't
# declare SSH_KEY must not fail here.
vault_ssh_install() {
  local secrets_dir="${1:-${NOMAD_SECRETS_DIR:-/secrets}}"
  local home_dir="${2:-${HOME:-/home/agent}}"
  local src_key="${secrets_dir}/ssh/id_ed25519"
  local src_kh="${secrets_dir}/ssh/known_hosts"

  [ -s "$src_key" ] || return 0

  mkdir -p "${home_dir}/.ssh"
  chmod 700 "${home_dir}/.ssh"
  # 0400 dest is not owner-writable — replace, don't overwrite in place.
  rm -f "${home_dir}/.ssh/id_ed25519"
  cp "$src_key" "${home_dir}/.ssh/id_ed25519"
  chmod 400 "${home_dir}/.ssh/id_ed25519"

  if [ -s "$src_kh" ]; then
    rm -f "${home_dir}/.ssh/known_hosts"
    cp "$src_kh" "${home_dir}/.ssh/known_hosts"
    chmod 644 "${home_dir}/.ssh/known_hosts"
  fi
}
