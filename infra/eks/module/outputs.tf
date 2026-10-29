# Outputs that embed the account id (the ECR registry and repository URLs, the IRSA role ARNs) or an
# account-specific host name (the RDS endpoint, the cluster endpoint) are sensitive: `terraform
# apply` and `terraform output` never print them, `terraform output -raw <name>` still returns one
# to a script, which masks it in CI logs before use.
output "cluster_name" {
  value = module.eks.cluster_name
}
output "region" {
  value = local.region
}
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}"
}
output "cluster_endpoint" {
  description = "For the caller's kubernetes and helm providers."
  value       = module.eks.cluster_endpoint
  sensitive   = true
}
output "cluster_certificate_authority_data" {
  description = "For the caller's kubernetes and helm providers (base64)."
  value       = module.eks.cluster_certificate_authority_data
}
output "ecr_registry" {
  description = "<account>.dkr.ecr.<region>.amazonaws.com: sensitive (the account id)."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"
  sensitive   = true
}
output "ecr_repositories" {
  value     = { for k, r in aws_ecr_repository.images : k => r.repository_url }
  sensitive = true
}
output "irsa_roles" {
  value = {
    lb               = module.lb_controller_irsa.iam_role_arn
    external_secrets = module.external_secrets_irsa.iam_role_arn
    external_dns     = module.external_dns_irsa.iam_role_arn
    cert_manager     = module.cert_manager_irsa.iam_role_arn
  }
  sensitive = true
}
output "rds_endpoint" {
  value     = module.rds.db_instance_endpoint
  sensitive = true
}
output "secrets" {
  description = "Per stack (network, or \"\" without networks): the Secrets Manager names the charts' externalSecrets read."
  value = { for k in keys(local.stacks) : k => {
    ycashd_rpc      = aws_secretsmanager_secret.ycashd_rpc[k].name
    yindex_postgres = aws_secretsmanager_secret.yindex_postgres[k].name
  } }
}
output "databases" {
  description = "Per stack: its yindex database on the one RDS instance."
  value       = local.stacks
}
output "domain" {
  value = var.domain
}
