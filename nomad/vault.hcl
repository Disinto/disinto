# =============================================================================
# nomad/vault.hcl — Single-node Vault configuration (dev-persisted seal)
#
# Part of the Nomad+Vault migration (S0.3, issue #823). Deployed to
# /etc/vault.d/vault.hcl on the factory dev box.
#
# Seal model: the single unseal key lives on disk at /etc/vault.d/unseal.key
# (0400 root) and is read by systemd ExecStartPost on every boot. This is
# the factory-dev-box-acceptable tradeoff — seal-key theft equals vault
# theft, but we avoid running a second Vault to auto-unseal the first.
#
# This is a factory dev-box baseline — TLS, HA, Raft storage, and audit
# devices are deliberately absent. Storage is the `file` backend (single
# node only). Listener is localhost-only, so no external TLS is needed.
# =============================================================================

# File storage backend — single-node only, no HA, no raft. State lives in
# /var/lib/vault/data which is created (root:root 0700) by
# lib/init/nomad/systemd-vault.sh before the unit starts.
storage "file" {
  path = "/var/lib/vault/data"
}

# Localhost-only listener. TLS is disabled because all callers are on the
# same box — flipping this to tls_disable=false is an audit-worthy change
# paired with cert provisioning.
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

# mlock prevents Vault's in-memory secrets from being swapped to disk. We
# keep it enabled; the systemd unit grants CAP_IPC_LOCK so mlock() succeeds.
disable_mlock = false

# Advertised API address — used by Vault clients on this host. Matches
# the listener above.
api_addr = "http://127.0.0.1:8200"

# UI on by default — same bind as listener, no TLS (localhost only).
ui = true
