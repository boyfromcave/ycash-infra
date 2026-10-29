# One Elastic IP per seed host, keyed seed-0 .. seed-<n-1>. Each host serves every network of its
# stack on that network's own port, so one address is a fixed seed of every network (pnSeed6_test
# per testnet profile, with its port). They must outlive every redeploy and every network reset:
# prevent_destroy makes Terraform refuse any plan that would release one, including
# `terraform destroy` and a lower seed_count. Retiring an address is a deliberate act by hand
# (../README.md, "Retiring an address").
locals {
  seeds = { for i in range(var.seed_count) : format("seed-%d", i) => i }
}

resource "aws_eip" "seed" {
  for_each = local.seeds

  #checkov:skip=CKV2_AWS_19:attached by the nodes layer (its own state) to a network interface, and kept while no instance runs
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })

  lifecycle {
    prevent_destroy = true
  }
}
