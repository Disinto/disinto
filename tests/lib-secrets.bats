#!/usr/bin/env bats
# =============================================================================
# tests/lib-secrets.bats — Unit tests for lib/secrets.sh (#695)
#
# Covers the public surface extracted from lib/env.sh:
#   - load_dotenv         : plain .env round-trip + FORGE_URL preservation
#   - load_dotenv_enc     : mocked SOPS-decrypt failure path
#   - load_secret         : precedence (env → age → default)
# =============================================================================

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

  # Isolate FACTORY_ROOT so the test cannot touch the real repo's .env / secrets/
  export FACTORY_ROOT="${BATS_TEST_TMPDIR}/factory"
  mkdir -p "$FACTORY_ROOT"

  # Isolate HOME so the age-key lookup in load_secret cannot hit the real user
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
}

# ── load_dotenv ─────────────────────────────────────────────────────────────

@test "load_dotenv loads plaintext .env into environment" {
  cat > "$FACTORY_ROOT/.env" <<EOF
TEST_VAR_A=value-a
TEST_VAR_B=value-b
EOF

  source "$REPO_ROOT/lib/secrets.sh"
  load_dotenv

  [ "$TEST_VAR_A" = "value-a" ]
  [ "$TEST_VAR_B" = "value-b" ]
}

@test "load_dotenv preserves pre-existing FORGE_URL across re-source" {
  # Simulates compose-injected FORGE_URL differing from on-disk .env (#364).
  cat > "$FACTORY_ROOT/.env" <<EOF
FORGE_URL=http://localhost:3000
OTHER_VAR=still-loaded
EOF

  export FORGE_URL="http://forgejo:3000"
  source "$REPO_ROOT/lib/secrets.sh"
  load_dotenv

  [ "$FORGE_URL" = "http://forgejo:3000" ]
  [ "$OTHER_VAR" = "still-loaded" ]
}

@test "load_dotenv is a no-op when file is absent" {
  source "$REPO_ROOT/lib/secrets.sh"
  run load_dotenv
  [ "$status" -eq 0 ]
}

# ── load_dotenv_enc ─────────────────────────────────────────────────────────

@test "load_dotenv_enc exits 1 on SOPS decrypt failure" {
  # Fake sops that always fails
  local fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/sops" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$fake_bin/sops"

  # Create a dummy .env.enc so the file-exists guard passes
  touch "$FACTORY_ROOT/.env.enc"

  # Run in subshell because load_dotenv_enc uses `exit 1` on decrypt failure.
  # PATH must keep system utilities (mktemp, grep) reachable — prepend fake bin.
  run bash -c "
    export PATH=\"$fake_bin:\$PATH\"
    export FACTORY_ROOT='$FACTORY_ROOT'
    source '$REPO_ROOT/lib/secrets.sh'
    load_dotenv_enc
  "

  [ "$status" -ne 0 ]
  [[ "$output" == *"decryption failed"* ]]
}

@test "load_dotenv_enc is a no-op when file is absent" {
  source "$REPO_ROOT/lib/secrets.sh"
  run load_dotenv_enc
  [ "$status" -eq 0 ]
}

@test "load_dotenv_enc is a no-op when sops is not on PATH" {
  touch "$FACTORY_ROOT/.env.enc"

  run bash -c "
    export PATH='/nonexistent-bin-dir'
    export FACTORY_ROOT='$FACTORY_ROOT'
    source '$REPO_ROOT/lib/secrets.sh'
    load_dotenv_enc
    echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# ── load_secret precedence ──────────────────────────────────────────────────

@test "load_secret returns default when nothing is set" {
  source "$REPO_ROOT/lib/secrets.sh"
  unset TEST_SECRET_DEFAULT 2>/dev/null || true
  run load_secret TEST_SECRET_DEFAULT "my-default"
  [ "$status" -eq 0 ]
  [ "$output" = "my-default" ]
}

@test "load_secret returns empty when nothing is set and no default" {
  source "$REPO_ROOT/lib/secrets.sh"
  unset TEST_SECRET_EMPTY 2>/dev/null || true
  run load_secret TEST_SECRET_EMPTY
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "load_secret prefers current environment over default" {
  source "$REPO_ROOT/lib/secrets.sh"
  export TEST_SECRET_ENV="from-environment"
  run load_secret TEST_SECRET_ENV "ignored"
  [ "$status" -eq 0 ]
  [ "$output" = "from-environment" ]
}

@test "load_secret decrypts age-encrypted file when env is unset" {
  if ! command -v age &>/dev/null || ! command -v age-keygen &>/dev/null; then
    skip "age/age-keygen not available"
  fi

  local age_key_dir="$HOME/.config/sops/age"
  mkdir -p "$age_key_dir"
  age-keygen -o "$age_key_dir/keys.txt" 2>/dev/null
  local pub_key
  pub_key=$(age-keygen -y "$age_key_dir/keys.txt")

  mkdir -p "$FACTORY_ROOT/secrets"
  printf 'age-decrypted-value' \
    | age -r "$pub_key" -o "$FACTORY_ROOT/secrets/TEST_SECRET_AGE.enc"

  source "$REPO_ROOT/lib/secrets.sh"
  unset TEST_SECRET_AGE 2>/dev/null || true
  run load_secret TEST_SECRET_AGE "fallback"
  [ "$status" -eq 0 ]
  [ "$output" = "age-decrypted-value" ]
}

@test "load_secret env wins over age-encrypted file" {
  if ! command -v age &>/dev/null || ! command -v age-keygen &>/dev/null; then
    skip "age/age-keygen not available"
  fi

  local age_key_dir="$HOME/.config/sops/age"
  mkdir -p "$age_key_dir"
  age-keygen -o "$age_key_dir/keys.txt" 2>/dev/null
  local pub_key
  pub_key=$(age-keygen -y "$age_key_dir/keys.txt")

  mkdir -p "$FACTORY_ROOT/secrets"
  printf 'age-loses' \
    | age -r "$pub_key" -o "$FACTORY_ROOT/secrets/TEST_SECRET_PREC.enc"

  source "$REPO_ROOT/lib/secrets.sh"
  export TEST_SECRET_PREC="env-wins"
  run load_secret TEST_SECRET_PREC "default"
  [ "$status" -eq 0 ]
  [ "$output" = "env-wins" ]
}
