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
  description = "Per enabled network: profile, ports and image (what network_configs carries, readable)."
  value       = { for k, c in local.network_config : k => { profile = c.profile, p2p_port = c.p2p_port, rpc_port = c.rpc_port, image = c.image } }
}

output "network_configs" {
  description = "Per enabled network: the config seedctl applies (`seedctl apply <key> <value>`), base64 of canonical JSON. Holds addresses, ports and image references only, no secret."
  value       = { for k, c in local.network_config : k => base64encode(jsonencode(c)) }
}

output "all_networks_config" {
  description = "Every enabled network's config in one value, for `seedctl sync <value>` (it also stops networks no longer listed)."
  value       = base64encode(jsonencode(local.network_config))
}

output "seedctl" {
  description = "This module's files/seedctl, gzip + base64: the deploy workflow installs it on every host before it runs a command, so a module update needs no new instance."
  value       = base64gzip(local.seedctl)
}
