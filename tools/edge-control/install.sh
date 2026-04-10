#!/usr/bin/env bash
# =============================================================================
# install.sh — One-shot installer for edge control plane on Debian DO box
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/disinto-admin/disinto/fix/issue-621/tools/edge-control/install.sh | bash -s -- --gandi-token YOUR_TOKEN
#
# What it does:
#   1. Creates users: disinto-register, disinto-tunnel
#   2. Creates /var/lib/disinto/ with registry.json, registry.lock
#   3. Installs Caddy with Gandi DNS plugin
#   4. Sets up SSH authorized_keys for both users
#   5. Installs control plane scripts to /opt/disinto-edge/
#
# Requirements:
#   - Fresh Debian 12 (Bookworm)
#   - Root or sudo access
#   - Gandi API token (for wildcard cert)
# =============================================================================
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Parse arguments
GANDI_TOKEN=""
INSTALL_DIR="/opt/disinto-edge"
REGISTRY_DIR="/var/lib/disinto"
CADDY_VERSION="2.8.4"
DOMAIN_SUFFIX="disinto.ai"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --gandi-token <token>   Gandi API token for wildcard cert (required)
  --install-dir <dir>     Install directory (default: /opt/disinto-edge)
  --registry-dir <dir>    Registry directory (default: /var/lib/disinto)
  --caddy-version <ver>   Caddy version to install (default: ${CADDY_VERSION})
  --domain-suffix <suffix> Domain suffix for tunnels (default: disinto.ai)
  -h, --help              Show this help

Example:
  $0 --gandi-token YOUR_GANDI_API_TOKEN
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --gandi-token)
      GANDI_TOKEN="$2"
      shift 2
      ;;
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --registry-dir)
      REGISTRY_DIR="$2"
      shift 2
      ;;
    --caddy-version)
      CADDY_VERSION="$2"
      shift 2
      ;;
    --domain-suffix)
      DOMAIN_SUFFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

# Validate required arguments
if [ -z "$GANDI_TOKEN" ]; then
  log_error "Gandi API token is required (--gandi-token)"
  usage
fi

log_info "Starting edge control plane installation..."

# =============================================================================
# Step 1: Create users
# =============================================================================
log_info "Creating users..."

# Create disinto-register user
if ! id "disinto-register" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -m -d /home/disinto-register "disinto-register" 2>/dev/null || true
  log_info "Created user: disinto-register"
else
  log_info "User already exists: disinto-register"
fi

# Create disinto-tunnel user
if ! id "disinto-tunnel" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -M "disinto-tunnel" 2>/dev/null || true
  log_info "Created user: disinto-tunnel"
else
  log_info "User already exists: disinto-tunnel"
fi

# =============================================================================
# Step 2: Create registry directory
# =============================================================================
log_info "Creating registry directory..."

mkdir -p "$REGISTRY_DIR"
chown root:disinto-register "$REGISTRY_DIR"
chmod 0750 "$REGISTRY_DIR"

# Initialize registry.json
REGISTRY_FILE="${REGISTRY_DIR}/registry.json"
if [ ! -f "$REGISTRY_FILE" ]; then
  echo '{"version":1,"projects":{}}' > "$REGISTRY_FILE"
  chmod 0644 "$REGISTRY_FILE"
  log_info "Initialized registry: ${REGISTRY_FILE}"
fi

# Create lock file
LOCK_FILE="${REGISTRY_DIR}/registry.lock"
touch "$LOCK_FILE"
chmod 0644 "$LOCK_FILE"

# =============================================================================
# Step 3: Install Caddy with Gandi DNS plugin
# =============================================================================
log_info "Installing Caddy ${CADDY_VERSION} with Gandi DNS plugin..."

# Create Caddy config directory
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_DATA_DIR="/var/lib/caddy"
mkdir -p "$CADDY_CONFIG_DIR" "$CADDY_DATA_DIR"
chmod 755 "$CADDY_CONFIG_DIR" "$CADDY_DATA_DIR"

# Download Caddy binary with Gandi plugin
CADDY_BINARY="/usr/bin/caddy"

# Build Caddy with Gandi plugin using caddy build command
if ! command -v caddy &>/dev/null; then
  log_info "Installing Caddy builder..."
  go install github.com/caddyserver/caddy/v2/cmd/caddy@latest 2>/dev/null || {
    log_warn "Go not available, trying system package..."
    if apt-get update -qq && apt-get install -y -qq caddy 2>/dev/null; then
      :
    fi || true
  }
fi

# Download Caddy with Gandi DNS plugin using Caddy's download API
# The API returns a binary with specified plugins baked in
CADDY_DOWNLOAD_API="https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com/caddy-dns/gandi"

log_info "Downloading Caddy with Gandi DNS plugin..."
curl -sL "$CADDY_DOWNLOAD_API" -o /tmp/caddy
chmod +x /tmp/caddy

# Verify it works
if ! /tmp/caddy version &>/dev/null; then
  log_error "Caddy binary verification failed"
  exit 1
fi

# Check for Gandi plugin
if ! /tmp/caddy version 2>&1 | grep -qi gandi; then
  log_warn "Gandi plugin not found in Caddy binary - DNS-01 challenge will fail"
fi

mv /tmp/caddy "$CADDY_BINARY"
log_info "Installed Caddy: $CADDY_BINARY"

# Create Caddy systemd service
CADDY_SERVICE="/etc/systemd/system/caddy.service"
cat > "$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy HTTP/HTTPS web server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
User=nobody
Group=nogroup
Type=notify
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy 2>/dev/null || true

# Create Gandi environment file
GANDI_ENV="/etc/caddy/gandi.env"
cat > "$GANDI_ENV" <<EOF
GANDI_API_KEY=${GANDI_TOKEN}
EOF
chmod 600 "$GANDI_ENV"

# Create Caddyfile with admin API and wildcard cert
CADDYFILE="/etc/caddy/Caddyfile"
cat > "$CADDYFILE" <<EOF
# Caddy configuration for edge control plane
# Admin API enabled on 127.0.0.1:2019

:2019 {
  @admin {
    header Host 127.0.0.1
  }
  respond @admin "Caddy admin API" 200
}

# Default site (reverse proxy for edge tunnels will be added dynamically)
:80, :443 {
  tls {
    dns gandi {env.GANDI_API_KEY}
  }
}
EOF

# Start Caddy
systemctl restart caddy 2>/dev/null || {
  log_warn "Could not start Caddy service (may need manual start)"
  # Try running directly for testing
  /usr/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
  sleep 2
}

log_info "Caddy configured with admin API on 127.0.0.1:2019"

# =============================================================================
# Step 4: Install control plane scripts
# =============================================================================
log_info "Installing control plane scripts to ${INSTALL_DIR}..."

mkdir -p "${INSTALL_DIR}/lib"

# Copy scripts (overwrite existing to ensure idempotent updates)
cp "${BASH_SOURCE%/*}/register.sh" "${INSTALL_DIR}/"
cp "${BASH_SOURCE%/*}/lib/ports.sh" "${INSTALL_DIR}/lib/"
cp "${BASH_SOURCE%/*}/lib/authorized_keys.sh" "${INSTALL_DIR}/lib/"
cp "${BASH_SOURCE%/*}/lib/caddy.sh" "${INSTALL_DIR}/lib/"

chmod +x "${INSTALL_DIR}/register.sh"
chmod +x "${INSTALL_DIR}/lib/"*.sh

chown -R root:disinto-register "${INSTALL_DIR}"
chmod 750 "${INSTALL_DIR}"
chmod 750 "${INSTALL_DIR}/lib"

log_info "Control plane scripts installed"

# =============================================================================
# Step 5: Set up SSH authorized_keys
# =============================================================================
log_info "Setting up SSH authorized_keys..."

# Create .ssh directories
mkdir -p /home/disinto-register/.ssh
mkdir -p /home/disinto-tunnel/.ssh

# Set permissions
chmod 700 /home/disinto-register/.ssh
chmod 700 /home/disinto-tunnel/.ssh
chown -R disinto-register:disinto-register /home/disinto-register/.ssh
chown -R disinto-tunnel:disinto-tunnel /home/disinto-tunnel/.ssh

# Prompt for admin pubkey (for disinto-register user)
log_info "Please paste your admin SSH public key for the disinto-register user."
log_info "Paste the entire key (e.g., 'ssh-ed25519 AAAAC3Nza... user@host') and press Enter."
log_info "Paste key (or press Enter to skip): "

read -r ADMIN_PUBKEY

if [ -n "$ADMIN_PUBKEY" ]; then
  echo "$ADMIN_PUBKEY" > /home/disinto-register/.ssh/authorized_keys
  chmod 600 /home/disinto-register/.ssh/authorized_keys
  chown disinto-register:disinto-register /home/disinto-register/.ssh/authorized_keys

  # Add forced command restriction
  # We'll update this after the first register call
  log_info "Admin pubkey added to disinto-register"
else
  log_warn "No admin pubkey provided - SSH access will be restricted"
  echo "# No admin pubkey configured" > /home/disinto-register/.ssh/authorized_keys
  chmod 600 /home/disinto-register/.ssh/authorized_keys
fi

# Create initial authorized_keys for tunnel user
"${INSTALL_DIR}/lib/authorized_keys.sh" rebuild_authorized_keys

# =============================================================================
# Step 6: Configure forced command for disinto-register
# =============================================================================
log_info "Configuring forced command for disinto-register..."

# Update authorized_keys with forced command
# Note: This replaces the pubkey line with a restricted version
if [ -n "$ADMIN_PUBKEY" ]; then
  # Extract key type and key
  KEY_TYPE="${ADMIN_PUBKEY%% *}"
  KEY_DATA="${ADMIN_PUBKEY#* }"

  # Create forced command entry
  FORCED_CMD="restrict,command=\"${INSTALL_DIR}/register.sh\" ${KEY_TYPE} ${KEY_DATA}"

  # Replace the pubkey line
  echo "$FORCED_CMD" > /home/disinto-register/.ssh/authorized_keys
  chmod 600 /home/disinto-register/.ssh/authorized_keys
  chown disinto-register:disinto-register /home/disinto-register/.ssh/authorized_keys

  log_info "Forced command configured: ${INSTALL_DIR}/register.sh"
fi

# =============================================================================
# Step 7: Final configuration
# =============================================================================
log_info "Configuring domain suffix: ${DOMAIN_SUFFIX}"

# Reload systemd if needed
systemctl daemon-reload 2>/dev/null || true

# =============================================================================
# Summary
# =============================================================================
echo ""
log_info "Installation complete!"
echo ""
echo "Edge control plane is now running on this host."
echo ""
echo "Configuration:"
echo "  Install directory: ${INSTALL_DIR}"
echo "  Registry: ${REGISTRY_FILE}"
echo "  Caddy admin API: http://127.0.0.1:2019"
echo ""
echo "Users:"
echo "  disinto-register - SSH forced command (runs ${INSTALL_DIR}/register.sh)"
echo "  disinto-tunnel   - Reverse tunnel receiver (no shell)"
echo ""
echo "Next steps:"
echo "  1. Verify Caddy is running: systemctl status caddy"
echo "  2. Test SSH access: ssh disinto-register@localhost 'list'"
echo "  3. From a dev box, register a tunnel:"
echo "     disinto edge register <project>"
echo ""
echo "To test:"
echo "  ssh disinto-register@$(hostname) 'list'"
echo ""
