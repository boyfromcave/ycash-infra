# The EKS service stack as a module: one VPC, one cluster, IRSA for the add-ons, ECR, RDS Postgres
# for yindex, the Secrets Manager secrets the charts read, and the add-ons as helm_release resources
# (../README.md; docs/eks-runbook.md is the order).
#
# No provider block and no backend: the caller chooses the account, the region and the state, and
# configures the kubernetes and helm providers from this module's cluster outputs (../main.tf, the
# example root, shows how). Every name, domain, zone and e-mail is a variable; nothing here names an
# account or a person. Outputs that embed the account id are marked sensitive (outputs.tf).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.80" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
