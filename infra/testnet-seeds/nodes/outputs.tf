output "public_ips" {
  description = "Per host: the public address (the Elastic IP)."
  value       = { for k, s in var.seeds : k => s.public_ip }
}

output "fixed_seeds" {
  description = "Per enabled network: every host as <address>:<port>, sorted: the list that goes into that profile's fixed seeds in the node."
  value       = { for k, n in local.enabled : k => sort([for s in local.seed_keys : "${var.seeds[s].public_ip}:${n.p2p_port}"]) }
}

output "instance_ids" {
  description = "Per host: the instance id (the SSM target: aws ssm start-session --target <id>)."
  value       = { for k, i in aws_instance.seed : k => i.id }
}

output "networks" {
  description = "Per enabled network: profile, ports and image, and its pool's stratum port and image when it has one (what network_configs carries, readable)."
  value = { for k, c in local.network_config : k => {
    profile   = c.profile, p2p_port = c.p2p_port, rpc_port = c.rpc_port, image = c.image,
    pool_port = c.pool == null ? null : c.pool.port, pool_image = c.pool == null ? null : c.pool.image
  } }
}

output "network_configs" {
  description = "Per enabled network: the config seedctl applies (`seedctl apply <key> <value>`), base64 of canonical JSON. Holds addresses, ports, image references and an explorer's certificate contact, no secret; sensitive (the caller's root marks it sensitive too)."
  value       = { for k, c in local.network_config : k => base64encode(jsonencode(c)) }
  # an explorer's certificate contact (var.explorer_acme_email, sensitive) is in it
  sensitive = true
}

output "all_networks_config" {
  description = "Every enabled network's config in one value, for `seedctl sync <value>` (it also stops networks no longer listed)."
  value       = base64encode(jsonencode(local.network_config))
  sensitive   = true
}

output "seedctl" {
  description = "This module's files/seedctl, gzip + base64: the deploy workflow installs it on every host before it runs a command, so a module update needs no new instance."
  value       = base64gzip(local.seedctl)
}

output "explorers" {
  description = "Per enabled network with an explorer: its public name and how its Inzyght image is made (no e-mail address, no secret)."
  value = { for k, n in local.enabled : k => {
    hostname = n.explorer.hostname
    url      = "${n.explorer.tls ? "https" : "http"}://${n.explorer.hostname}/"
    inzyght  = n.explorer.build == null ? n.explorer.image : "built on the host from ${n.explorer.build.repo} at ${n.explorer.build.commit}"
  } if n.explorer != null }
}

output "host_files" {
  description = "The files seedctl needs for an apply or a reset beyond itself (the prefix tools; for an explorer, seedctl-explorer and in build mode the Inzyght build context; for a lightwallet, seedctl-lightwallet), as one JSON map of name to { mode, content }, gzip + base64: the deploy workflow hands it to `seedctl install-files` before every run, as it installs seedctl. Empty when there are none. No secret."
  value       = length(local.host_files) == 0 ? "" : base64gzip(jsonencode(local.host_files))
}

output "lightwallets" {
  description = "Per enabled network with a lightwallet: its public name and how to reach it, native gRPC (the apps: host:port) and gRPC-web (the web wallet: a URL); no e-mail address, no secret."
  value = { for k, n in local.enabled : k => {
    hostname     = n.lightwallet.hostname
    grpc         = "${n.lightwallet.hostname}:${n.lightwallet.tls ? 443 : 80}"
    url          = "${n.lightwallet.tls ? "https" : "http"}://${n.lightwallet.hostname}"
    tls          = n.lightwallet.tls
    lightwalletd = n.lightwallet.image
  } if n.lightwallet != null }
}
