output "cluster_name" { value = module.eks.cluster_name }
output "region" { value = var.region }
output "kubeconfig_command" { value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}" }
output "ecr_repositories" { value = { for k, r in aws_ecr_repository.images : k => r.repository_url } }
output "ecr_registry" { value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com" }
output "irsa_roles" {
  value = {
    lb               = module.lb_controller_irsa.iam_role_arn
    external_secrets = module.external_secrets_irsa.iam_role_arn
    external_dns     = module.external_dns_irsa.iam_role_arn
    cert_manager     = module.cert_manager_irsa.iam_role_arn
  }
}
output "rds_endpoint" { value = module.rds.db_instance_endpoint }
output "secrets" {
  value = {
    ycashd_rpc      = aws_secretsmanager_secret.ycashd_rpc.name
    yindex_postgres = aws_secretsmanager_secret.yindex_postgres.name
  }
}
output "domain" { value = var.domain }
