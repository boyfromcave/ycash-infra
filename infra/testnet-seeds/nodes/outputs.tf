output "public_ips" {
  description = "Per seed: the public address (the Elastic IP)."
  value       = { for k, s in var.seeds : k => s.public_ip }
}

output "fixed_seeds" {
  description = "Every seed as <address>:<port>, sorted: the list that goes into the node's fixed seeds."
  value       = sort([for k, s in var.seeds : "${s.public_ip}:${var.p2p_port}"])
}

output "instance_ids" {
  description = "Per seed: the instance id (for SSM: aws ssm start-session --target <id>)."
  value       = { for k, i in aws_instance.seed : k => i.id }
}

output "images" {
  description = "Per seed: the image it runs."
  value       = local.image_of
}
