# The EKS cluster the chart is promoted to. Deliberately boring: one VPC, one managed node
# group, IRSA for the add-ons values-eks.yaml expects (EBS CSI, Load Balancer Controller,
# External Secrets, external-dns, cert-manager's Route53 DNS-01), the ECR repositories, the gp3
# StorageClass, RDS Postgres for yindex (rds.tf), the two Secrets Manager secrets (secrets.tf)
# and the add-ons themselves as helm_release resources (addons.tf). One `terraform apply` from
# an empty account to a cluster the chart deploys onto; docs/eks-runbook.md is the order.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.80" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" { region = var.region }

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=7c1f791efd61f326ed6102d564d1a65d1eceedf0" # v5.21.0

  name                = var.name
  cidr                = "10.40.0.0/16"
  azs                 = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets     = ["10.40.0.0/19", "10.40.32.0/19", "10.40.64.0/19"]
  public_subnets      = ["10.40.96.0/22", "10.40.100.0/22", "10.40.104.0/22"]
  database_subnets    = ["10.40.112.0/24", "10.40.113.0/24", "10.40.114.0/24"]
  enable_nat_gateway  = true
  single_nat_gateway  = var.single_nat_gateway
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=8a0efdbbc84180a26e0bacfd2b6fcfceac53b3b6" # v20.37.2

  cluster_name                             = var.name
  cluster_version                          = var.kubernetes_version
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  cluster_addons = {
    coredns            = {}
    kube-proxy         = {}
    vpc-cni            = {}
    aws-ebs-csi-driver = { service_account_role_arn = module.ebs_csi_irsa.iam_role_arn }
  }
  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_desired
      disk_size      = 100
    }
  }
}

# Modules are pinned by commit (the registry's version constraints are not in .terraform.lock.hcl, so
# `~>` would float): the newest release inside the constraint the file had, the tag in the comment.
# Bump: `git ls-remote --tags https://github.com/terraform-aws-modules/terraform-aws-<name>.git`.

# ---- IRSA: one role per add-on, bound to its ServiceAccount (namespace:name) ------------------
module "ebs_csi_irsa" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=c29ec1ed409683086f63f83ff5b10a6f3c296ef2" # v5.60.0

  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers        = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"] } }
}

module "lb_controller_irsa" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=c29ec1ed409683086f63f83ff5b10a6f3c296ef2" # v5.60.0

  role_name                              = "${var.name}-lb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers                         = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["kube-system:aws-load-balancer-controller"] } }
}

module "external_secrets_irsa" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=c29ec1ed409683086f63f83ff5b10a6f3c296ef2" # v5.60.0

  role_name                             = "${var.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_prefix}/*"]
  oidc_providers                        = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["external-secrets:external-secrets"] } }
}

module "external_dns_irsa" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=c29ec1ed409683086f63f83ff5b10a6f3c296ef2" # v5.60.0

  role_name                     = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [local.hosted_zone_arn]
  oidc_providers                = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["external-dns:external-dns"] } }
}

# cert-manager solves ACME DNS-01 in the same hosted zone (addons.tf: ClusterIssuer letsencrypt-prod).
module "cert_manager_irsa" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=c29ec1ed409683086f63f83ff5b10a6f3c296ef2" # v5.60.0

  role_name                     = "${var.name}-cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = [local.hosted_zone_arn]
  oidc_providers                = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["cert-manager:cert-manager"] } }
}

locals {
  hosted_zone_arn = "arn:aws:route53:::hostedzone/${var.hosted_zone_id}"
}

# ---- the four images -----------------------------------------------------------------------------
resource "aws_ecr_repository" "images" {
  for_each             = toset(["ycash/ycashd", "ycash/lightwalletd", "ycash/yindex", "ycash/web"])
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

# ---- in-cluster: the default StorageClass ----------------------------------------------------
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [module.eks]
}

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
