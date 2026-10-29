# Offline: infra/eks/module against mocked providers, with the upstream modules (VPC, EKS, IRSA, RDS)
# overridden, so only this module's own resources are planned. Checks the per-network secrets and
# databases, the network-less default, the outputs that must stay sensitive, and the refusals.
# Run: terraform init -backend=false && terraform test   (make eks-validate)
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["xx-example-1a", "xx-example-1b", "xx-example-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "000000000000" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { name = "xx-example-1" }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

override_module {
  target = module.vpc
  outputs = {
    vpc_id                     = "vpc-00000000000000000"
    vpc_cidr_block             = "10.40.0.0/16"
    private_subnets            = ["subnet-0", "subnet-1", "subnet-2"]
    database_subnet_group_name = "example"
  }
}
override_module {
  target = module.eks
  outputs = {
    cluster_name                       = "example"
    cluster_endpoint                   = "https://example.invalid"
    cluster_certificate_authority_data = "ZXhhbXBsZQ=="
    oidc_provider_arn                  = "arn:aws:iam::000000000000:oidc-provider/example"
    node_security_group_id             = "sg-00000000000000000"
  }
}
override_module {
  target  = module.rds
  outputs = { db_instance_address = "db.example.invalid", db_instance_endpoint = "db.example.invalid:5432" }
}
override_module {
  target  = module.ebs_csi_irsa
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/example-ebs" }
}
override_module {
  target  = module.lb_controller_irsa
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/example-lb" }
}
override_module {
  target  = module.external_secrets_irsa
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/example-es" }
}
override_module {
  target  = module.external_dns_irsa
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/example-dns" }
}
override_module {
  target  = module.cert_manager_irsa
  outputs = { iam_role_arn = "arn:aws:iam::000000000000:role/example-cm" }
}

variables {
  domain         = "testnet.example.org"
  hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  acme_email     = "ops@example.org"
}

run "single_endpoint_by_default" {
  command = plan
  assert {
    condition     = jsonencode(keys(output.secrets)) == jsonencode([""]) && output.secrets[""].ycashd_rpc == "ycash/lite/ycashd-rpc" && output.secrets[""].yindex_postgres == "ycash/lite/yindex-postgres"
    error_message = "without networks: the two secrets without a network segment"
  }
  assert {
    condition     = output.databases[""] == "yindex" && length(kubernetes_job_v1.yindex_databases) == 0
    error_message = "without networks: the instance's own database, no Job"
  }
  assert {
    condition     = jsonencode(sort(keys(aws_ecr_repository.images))) == jsonencode(["ycash/lightwalletd", "ycash/web", "ycash/ycashd", "ycash/yindex"])
    error_message = "the four ECR repositories"
  }
  assert {
    condition     = module.vpc.vpc_cidr_block == "10.40.0.0/16" && cidrsubnet("10.40.0.0/16", 6, 24) == "10.40.96.0/22" && cidrsubnet("10.40.0.0/16", 8, 114) == "10.40.114.0/24"
    error_message = "the computed subnets keep the original layout"
  }
}

run "one_namespace_per_network" {
  variables {
    networks       = ["yb-fast", "yb-slow", "legacy"]
    secrets_prefix = "ycash/testnet"
    ecr_images     = ["ycashd", "ycashd-legacy", "lightwalletd", "yindex", "web"]
  }
  assert {
    condition     = output.secrets["yb-fast"].ycashd_rpc == "ycash/testnet/yb-fast/ycashd-rpc" && output.secrets["legacy"].yindex_postgres == "ycash/testnet/legacy/yindex-postgres"
    error_message = "one secret pair per network, under the prefix"
  }
  assert {
    condition     = output.databases["yb-fast"] == "yindex_yb_fast" && output.databases["yb-slow"] == "yindex_yb_slow" && output.databases["legacy"] == "yindex_legacy"
    error_message = "one database per network"
  }
  assert {
    condition     = endswith(local.yindex_postgres_url["yb-slow"], "@db.example.invalid:5432/yindex_yb_slow?sslmode=require")
    error_message = "each url names its own database, TLS required"
  }
  assert {
    condition     = length(kubernetes_job_v1.yindex_databases) == 1 && kubernetes_job_v1.yindex_databases[0].spec[0].template[0].spec[0].container[0].env[0].value == "yindex_legacy yindex_yb_fast yindex_yb_slow"
    error_message = "the Job creates every network's database"
  }
  assert {
    condition     = kubernetes_job_v1.yindex_databases[0].spec[0].template[0].spec[0].container[0].security_context[0].read_only_root_filesystem && kubernetes_job_v1.yindex_databases[0].spec[0].template[0].spec[0].security_context[0].run_as_non_root
    error_message = "the Job runs non-root on a read-only root"
  }
  assert {
    condition     = contains(keys(aws_ecr_repository.images), "ycash/ycashd-legacy")
    error_message = "ecr_images adds repositories"
  }
}

run "refuses_a_bad_network_name" {
  command = plan
  variables {
    networks = ["YB_FAST"]
  }
  expect_failures = [var.networks]
}

run "refuses_a_bad_zone_id" {
  command = plan
  variables {
    hosted_zone_id = "example.org"
  }
  expect_failures = [var.hosted_zone_id]
}
