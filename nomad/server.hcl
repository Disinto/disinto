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
