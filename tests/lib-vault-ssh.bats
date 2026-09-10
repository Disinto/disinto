#!/usr/bin/env bats
# =============================================================================
# tests/lib-vault-ssh.bats — Vault-held SSH key material for the runner
#
# SSH keys are file secrets (kv/disinto/runner/SSH_KEY), not env vars and
# not a bind-mount of the host's ~/.ssh. The runner installs them into
# $HOME/.ssh with ssh-required modes. Agents must never receive them.
# =============================================================================

load '../lib/vault-ssh.sh'

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  HOME_DIR="${BATS_TEST_TMPDIR}/home"
  SECRETS="${BATS_TEST_TMPDIR}/secrets"
  mkdir -p "$HOME_DIR" "$SECRETS"
}

@test "SSH_KEY and SSH_KNOWN_HOSTS are file secrets; tokens are not" {
  vault_ssh_is_file_secret SSH_KEY
  vault_ssh_is_file_secret SSH_KNOWN_HOSTS
  ! vault_ssh_is_file_secret GITHUB_TOKEN
  ! vault_ssh_is_file_secret DEPLOY_KEY
}

@test "relpath maps SSH_KEY to ssh/id_ed25519 and known_hosts beside it" {
  [ "$(vault_ssh_relpath SSH_KEY)" = "ssh/id_ed25519" ]
  [ "$(vault_ssh_relpath SSH_KNOWN_HOSTS)" = "ssh/known_hosts" ]
  run vault_ssh_relpath GITHUB_TOKEN
  [ "$status" -ne 0 ]
}

@test "install is a no-op when the key file is absent" {
  vault_ssh_install "$SECRETS" "$HOME_DIR"
  [ ! -e "${HOME_DIR}/.ssh/id_ed25519" ]
}

@test "install copies the key to ~/.ssh/id_ed25519 mode 0400, dir 0700" {
  mkdir -p "${SECRETS}/ssh"
  printf 'fake-pem\n' > "${SECRETS}/ssh/id_ed25519"
  vault_ssh_install "$SECRETS" "$HOME_DIR"
  [ -f "${HOME_DIR}/.ssh/id_ed25519" ]
  [ "$(stat -c '%a' "${HOME_DIR}/.ssh")" = "700" ]
  [ "$(stat -c '%a' "${HOME_DIR}/.ssh/id_ed25519")" = "400" ]
  [ "$(cat "${HOME_DIR}/.ssh/id_ed25519")" = "fake-pem" ]
}

@test "install copies known_hosts when present, ignores when absent" {
  mkdir -p "${SECRETS}/ssh"
  printf 'fake-pem\n' > "${SECRETS}/ssh/id_ed25519"
  vault_ssh_install "$SECRETS" "$HOME_DIR"
  [ ! -e "${HOME_DIR}/.ssh/known_hosts" ]

  printf 'host ssh-ed25519 AAAA\n' > "${SECRETS}/ssh/known_hosts"
  vault_ssh_install "$SECRETS" "$HOME_DIR"
  [ "$(cat "${HOME_DIR}/.ssh/known_hosts")" = "host ssh-ed25519 AAAA" ]
  [ "$(stat -c '%a' "${HOME_DIR}/.ssh/known_hosts")" = "644" ]
}

@test "allowlist declares SSH_KEY and SSH_KNOWN_HOSTS as runner secrets" {
  grep -q 'SSH_KEY' "${REPO_ROOT}/action-vault/vault-env.sh"
  grep -q 'SSH_KNOWN_HOSTS' "${REPO_ROOT}/action-vault/vault-env.sh"
}

@test "lib/env.sh unsets SSH_KEY so agents cannot inherit it" {
  grep -q 'unset SSH_KEY' "${REPO_ROOT}/lib/env.sh"
}

@test "vault-runner.hcl renders SSH_KEY as a 0400 file, not env=true" {
  local job="${REPO_ROOT}/nomad/jobs/vault-runner.hcl"
  grep -q 'secrets/ssh/id_ed25519' "$job"
  grep -q 'secrets/ssh/known_hosts' "$job"
  grep -q 'kv/data/disinto/runner/SSH_KEY' "$job"
  # Token bundle (secrets/runner.env) must not mention SSH_KEY.
  ! awk '/secrets\/runner.env/,/^EOT/' "$job" | grep -q SSH_KEY
  grep -A5 'secrets/ssh/id_ed25519' "$job" | grep -q '0400'
}

@test "per-secret policy + role exist for SSH_KEY and SSH_KNOWN_HOSTS" {
  [ -f "${REPO_ROOT}/vault/policies/runner-SSH_KEY.hcl" ]
  [ -f "${REPO_ROOT}/vault/policies/runner-SSH_KNOWN_HOSTS.hcl" ]
  grep -q 'kv/data/disinto/runner/SSH_KEY' "${REPO_ROOT}/vault/policies/runner-SSH_KEY.hcl"
  grep -q 'name:      runner-SSH_KEY' "${REPO_ROOT}/vault/roles.yaml"
  grep -q 'name:      runner-SSH_KNOWN_HOSTS' "${REPO_ROOT}/vault/roles.yaml"
}

@test "runner entrypoint installs vault SSH before dispatching the formula" {
  local ep="${REPO_ROOT}/docker/runner/entrypoint-runner.sh"
  grep -q 'vault-ssh.sh' "$ep"
  local src_line install_line
  src_line="$(grep -nF 'vault-ssh.sh' "$ep" | head -1 | cut -d: -f1)"
  install_line="$(grep -nF 'vault_ssh_install' "$ep" | head -1 | cut -d: -f1)"
  local formula_line
  formula_line="$(grep -nF 'formula_sh=' "$ep" | head -1 | cut -d: -f1)"
  [ -n "$src_line" ]
  [ "$src_line" -lt "$install_line" ]
  [ "$install_line" -lt "$formula_line" ]
}

@test "docker dispatcher mounts SSH_KEY as a file, not -e SSH_KEY=" {
  local d="${REPO_ROOT}/docker/edge/dispatcher.sh"
  grep -q 'vault_ssh_is_file_secret' "$d"
  grep -q '/secrets/' "$d"
}

@test "docker dispatcher skips host ~/.ssh bind when SSH_KEY is in the action" {
  local d="${REPO_ROOT}/docker/edge/dispatcher.sh"
  grep -q 'SSH_KEY from vault' "$d"
}
