# The module's outputs, for the Makefile (eks-push, eks-deploy, eks-smoke). The account-bearing ones
# stay sensitive: `terraform output` shows <sensitive>, `terraform output -raw` returns the value.
output "cluster_name" { value = module.eks.cluster_name }
output "region" { value = module.eks.region }
output "kubeconfig_command" { value = module.eks.kubeconfig_command }
output "ecr_registry" {
  value     = module.eks.ecr_registry
  sensitive = true
}
output "ecr_repositories" {
  value     = module.eks.ecr_repositories
  sensitive = true
}
output "irsa_roles" {
  value     = module.eks.irsa_roles
  sensitive = true
}
output "rds_endpoint" {
  value     = module.eks.rds_endpoint
  sensitive = true
}
output "secrets" { value = module.eks.secrets }
output "domain" { value = module.eks.domain }
