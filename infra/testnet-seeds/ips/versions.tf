# The seed addresses: one Elastic IP per testnet seed, kept forever (README.md beside this directory).
#
# A module, called from the operator's own root (see ../README.md, "Calling it from a private
# repository"): it has no provider block and no backend, so the caller chooses the account, the
# region and where the state lives. The caller's root holds, for example:
#
#   terraform {
#     backend "s3" {}   # values from `terraform init -backend-config=backend.hcl`, never committed
#   }
#   provider "aws" { region = var.region }
#
# with a backend.hcl like (fake values):
#
#   bucket       = "example-tfstate-bucket"
#   key          = "testnet-seeds/ips.tfstate"
#   region       = "us-east-1"
#   encrypt      = true
#   use_lockfile = true
#
# The provider is pinned exactly; the caller's .terraform.lock.hcl records its hashes.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.70.0" }
  }
}
