# The example root of infra/eks/module (versions.tf). Everything it creates is the module's; this
# file only configures the providers and passes the variables through.
provider "aws" {
  region = var.region
}

module "eks" {
  source = "./module"

  name                = var.name
  kubernetes_version  = var.kubernetes_version
  node_instance_types = var.node_instance_types
  node_min            = var.node_min
  node_max            = var.node_max
  node_desired        = var.node_desired
  single_nat_gateway  = var.single_nat_gateway
  domain              = var.domain
  hosted_zone_id      = var.hosted_zone_id
  acme_email          = var.acme_email
  secrets_prefix      = var.secrets_prefix
  networks            = var.networks
  cluster_admin_arns  = var.cluster_admin_arns
  rds_instance_class  = var.rds_instance_class
  rds_allocated_gb    = var.rds_allocated_gb
  rds_multi_az        = var.rds_multi_az
}

# The kubernetes and helm providers authenticate to the module's cluster with `aws eks get-token`.
# They need the cluster at plan time; on a first apply the exec auth defers until it exists (the
# runbook's fallback: `terraform apply -target=module.eks.module.eks` first).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
