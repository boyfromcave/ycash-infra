# One Elastic IP per seed, keyed seed-0 .. seed-<n-1>. These addresses are compiled into the node as
# its fixed seeds (pnSeed6_test), so they must outlive every redeploy and every testnet reset:
# prevent_destroy makes Terraform refuse any plan that would release one, including
# `terraform destroy` and a lower seed_count. Retiring an address is a deliberate act by hand
# (../README.md, "Retiring an address").
locals {
  seeds = { for i in range(var.seed_count) : format("seed-%d", i) => i }
}

resource "aws_eip" "seed" {
  for_each = local.seeds

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })

  lifecycle {
    prevent_destroy = true
  }
}
