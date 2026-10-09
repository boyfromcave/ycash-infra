# The EKS cluster the chart is promoted to. Deliberately boring: one VPC, one managed node
# group, IRSA for the add-ons the values-eks.yaml expects (EBS CSI, Load Balancer Controller,
# External Secrets, external-dns). Add-ons are installed with helm after apply (README).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

provider "aws" { region = var.region }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"
  name            = var.name
  cidr            = "10.40.0.0/16"
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.40.0.0/19", "10.40.32.0/19", "10.40.64.0/19"]
  public_subnets  = ["10.40.96.0/22", "10.40.100.0/22", "10.40.104.0/22"]
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

data "aws_availability_zones" "available" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"
  cluster_name    = var.name
  cluster_version = var.kubernetes_version
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = { service_account_role_arn = module.ebs_csi_irsa.iam_role_arn }
  }
  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types
      min_size     = var.node_min
      max_size     = var.node_max
      desired_size = var.node_desired
      disk_size    = 100
    }
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"
  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"] } }
}

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"
  role_name                              = "${var.name}-lb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["kube-system:aws-load-balancer-controller"] } }
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"
  role_name                             = "${var.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:${var.region}:*:secret:ycash/*"]
  oidc_providers = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["external-secrets:external-secrets"] } }
}

module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"
  role_name                     = "${var.name}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = var.hosted_zone_arns
  oidc_providers = { main = { provider_arn = module.eks.oidc_provider_arn, namespace_service_accounts = ["external-dns:external-dns"] } }
}

resource "aws_ecr_repository" "images" {
  for_each             = toset(["ycash/ycashd", "ycash/lightwalletd", "ycash/yindex", "ycash/web"])
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "kubernetes_storage_class" "gp3" {
  metadata { name = "gp3" annotations = { "storageclass.kubernetes.io/is-default-class" = "true" } }
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
