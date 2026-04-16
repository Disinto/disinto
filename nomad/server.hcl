# =============================================================================
# nomad/server.hcl — Single-node combined server+client configuration
#
# Part of the Nomad+Vault migration (S0.2, issue #822). Deployed to
# /etc/nomad.d/server.hcl on the factory dev box alongside client.hcl.
#
# This file owns: agent role, ports, bind, data directory.
# client.hcl owns: Docker driver plugin config + host_volume declarations.
#
# NOTE: On single-node setups these two files could be merged into one
# (Nomad auto-merges every *.hcl under -config=/etc/nomad.d). The split is
# purely for readability — role/bind/port vs. plugin/volume wiring.
#
# This is a factory dev-box baseline — TLS, ACLs, gossip encryption, and
# consul/vault integration are deliberately absent and land in later steps.
# =============================================================================

data_dir  = "/var/lib/nomad"
bind_addr = "127.0.0.1"
log_level = "INFO"

# All Nomad agent traffic stays on localhost — the factory box does not
# federate with peers. Ports are the Nomad defaults, pinned here so that
# future changes to these numbers are a visible diff.
ports {
  http = 4646
  rpc  = 4647
  serf = 4648
}

# Single-node combined mode: this agent is both the only server and the
# only client. bootstrap_expect=1 makes the server quorum-of-one.
server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled = true
}

# Advertise localhost to self to avoid surprises if the default IP
# autodetection picks a transient interface (e.g. docker0, wg0).
advertise {
  http = "127.0.0.1"
  rpc  = "127.0.0.1"
  serf = "127.0.0.1"
}

# UI on by default — same bind as http, no TLS (localhost only).
ui {
  enabled = true
}

# ─── Vault integration (S2.3, issue #881) ───────────────────────────────────
# Nomad jobs exchange their short-lived workload-identity JWT (signed by
# nomad's built-in signer at /.well-known/jwks.json on :4646) for a Vault
# token carrying the policies named by the role in `vault { role = "..." }`
# of each jobspec — no shared VAULT_TOKEN in job env.
#
# The JWT auth path (jwt-nomad) + per-role bindings live on the Vault
# side, written by lib/init/nomad/vault-nomad-auth.sh + tools/vault-apply-roles.sh.
# Roles are defined in vault/roles.yaml.
#
# `default_identity.aud = ["vault.io"]` matches bound_audiences on every
# role in vault/roles.yaml — a drift here would silently break every job's
# Vault token exchange at placement time.
vault {
  enabled = true
  address = "http://127.0.0.1:8200"

  default_identity {
    aud = ["vault.io"]
    ttl = "1h"
  }
}
