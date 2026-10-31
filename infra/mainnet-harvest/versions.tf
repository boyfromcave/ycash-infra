# The mainnet harvest: a results bucket and a one-shot EC2 launch template (README.md).
#
# A module, called from the operator's own root: it has no provider block and no backend, so the
# caller chooses the account, the region and where the state lives, as infra/testnet-seeds does.
# The caller's root holds, for example:
#
#   terraform {
#     backend "s3" {}   # values from `terraform init -backend-config=backend.hcl`, never committed
#   }
#   provider "aws" { region = var.region }
#
# The provider is pinned exactly; the caller's .terraform.lock.hcl records its hashes.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.70.0" }
  }
}
