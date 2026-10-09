output "cluster_name"          { value = module.eks.cluster_name }
output "kubeconfig_command"    { value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}" }
output "ecr_repositories"      { value = { for k, r in aws_ecr_repository.images : k => r.repository_url } }
output "irsa_roles"            { value = { lb = module.lb_controller_irsa.iam_role_arn, external_secrets = module.external_secrets_irsa.iam_role_arn, external_dns = module.external_dns_irsa.iam_role_arn } }
