# The example root: the module in ./module with the providers and (for a shared state) a backend
# around it, as an operator's private root holds them. `make eks-up` / `eks-validate` run here.
#
# A private root calls the same module at a pinned commit of this repository:
#
#   module "eks" {
#     source = "git::https://github.com/<owner>/ycash-infra.git//infra/eks/module?ref=<sha>"
#     ...
#   }
#
# and keeps its state in its own bucket:
#
#   terraform {
#     backend "s3" {}   # values from `terraform init -backend-config=backend.hcl`, never committed
#   }
#
# with a backend.hcl like (fake values):
#
#   bucket       = "example-tfstate-bucket"
#   key          = "eks/testnet.tfstate"
#   region       = "us-east-1"
#   encrypt      = true
#   use_lockfile = true
#
# Without a backend (as here) the state is a local file, gitignored: fine for one operator's
# laptop, never for a shared deployment.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.80" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
