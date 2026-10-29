# `seeds` is what the nodes layer takes (its var.seeds), through the caller's terraform_remote_state
# or copied by hand. The addresses are public by nature (they are the seeds); the allocation ids are
# not secret but say nothing useful outside the account.
output "seeds" {
  description = "Per seed: the Elastic IP's allocation id and public address."
  value       = { for k, e in aws_eip.seed : k => { allocation_id = e.allocation_id, public_ip = e.public_ip } }
}

output "public_ips" {
  description = "Per seed: the public address."
  value       = { for k, e in aws_eip.seed : k => e.public_ip }
}
