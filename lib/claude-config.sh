#!/usr/bin/env bash
# lib/claude-config.sh — Shared Claude config directory helpers (#641)
#
# Provides setup_claude_config_dir() for creating/migrating CLAUDE_CONFIG_DIR
# and _env_set_idempotent() for writing env vars to .env files.
#
# Requires: CLAUDE_CONFIG_DIR, CLAUDE_SHARED_DIR (set by lib/env.sh)

# Idempotent .env writer.
# Usage: _env_set_idempotent KEY VALUE FILE
_env_set_idempotent() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    local existing
    existing=$(grep "^${key}=" "$file" | head -1 | cut -d= -f2-)
    if [ "$existing" != "$value" ]; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    fi
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

# Create the shared CLAUDE_CONFIG_DIR, optionally migrating ~/.claude.
# Usage: setup_claude_config_dir [auto_yes]
setup_claude_config_dir() {
  local auto_yes="${1:-false}"
  local home_claude="${HOME}/.claude"

  # Create the shared config directory (idempotent)
  install -d -m 0700 -o "$USER" "$CLAUDE_CONFIG_DIR"
  echo "Claude:  ${CLAUDE_CONFIG_DIR} (ready)"

  # If ~/.claude is already a symlink to CLAUDE_CONFIG_DIR, nothing to do
  if [ -L "$home_claude" ]; then
    local link_target
    link_target=$(readlink -f "$home_claude")
    local config_real
    config_real=$(readlink -f "$CLAUDE_CONFIG_DIR")
    if [ "$link_target" = "$config_real" ]; then
      echo "Claude:  ${home_claude} -> ${CLAUDE_CONFIG_DIR} (symlink OK)"
      return 0
    fi
  fi

  local home_exists=false home_nonempty=false
  local config_nonempty=false

  # Check ~/.claude (skip if it's a symlink — already handled above)
  if [ -d "$home_claude" ] && [ ! -L "$home_claude" ]; then
    home_exists=true
    if [ -n "$(ls -A "$home_claude" 2>/dev/null)" ]; then
      home_nonempty=true
    fi
  fi

  # Check CLAUDE_CONFIG_DIR contents
  if [ -n "$(ls -A "$CLAUDE_CONFIG_DIR" 2>/dev/null)" ]; then
    config_nonempty=true
  fi

  # Case: both non-empty — abort, operator must reconcile
  if [ "$home_nonempty" = true ] && [ "$config_nonempty" = true ]; then
    echo "ERROR: both ${home_claude} and ${CLAUDE_CONFIG_DIR} exist and are non-empty" >&2
    echo "  Reconcile manually: merge or remove one, then re-run disinto init" >&2
    return 1
  fi

  # Case: ~/.claude exists and CLAUDE_CONFIG_DIR is empty — offer migration
  if [ "$home_nonempty" = true ] && [ "$config_nonempty" = false ]; then
    local do_migrate=false
    if [ "$auto_yes" = true ]; then
      do_migrate=true
    elif [ -t 0 ]; then
      read -rp "Migrate ${home_claude} to ${CLAUDE_CONFIG_DIR}? [Y/n] " confirm
      if [[ ! "$confirm" =~ ^[Nn] ]]; then
        do_migrate=true
      fi
    else
      echo "Warning: ${home_claude} exists but cannot prompt for migration (no TTY)" >&2
      echo "  Re-run with --yes to auto-migrate, or move files manually" >&2
      return 0
    fi

    if [ "$do_migrate" = true ]; then
      # Move contents (not the dir itself) to preserve CLAUDE_CONFIG_DIR ownership
      cp -a "$home_claude/." "$CLAUDE_CONFIG_DIR/"
      rm -rf "$home_claude"
      ln -sfn "$CLAUDE_CONFIG_DIR" "$home_claude"
      echo "Claude:  migrated ${home_claude} -> ${CLAUDE_CONFIG_DIR}"
      return 0
    fi
  fi

  # Case: ~/.claude exists but is empty, or doesn't exist — create symlink
  if [ "$home_exists" = true ] && [ "$home_nonempty" = false ]; then
    rmdir "$home_claude" 2>/dev/null || true
  fi
  if [ ! -e "$home_claude" ]; then
    ln -sfn "$CLAUDE_CONFIG_DIR" "$home_claude"
    echo "Claude:  ${home_claude} -> ${CLAUDE_CONFIG_DIR} (symlink created)"
  fi
}
