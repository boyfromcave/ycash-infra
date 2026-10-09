# infra/eks

```bash
terraform init && terraform apply -var hosted_zone_arns='["arn:aws:route53:::hostedzone/Z..."]'
$(terraform output -raw kubeconfig_command)
# add-ons the chart expects (each one helm install; the IRSA role ARNs are in `terraform output irsa_roles`):
#   envoy-gateway (oci://docker.io/envoyproxy/gateway-helm), cert-manager (+ a ClusterIssuer letsencrypt-prod),
#   aws-load-balancer-controller, external-secrets (+ ClusterSecretStore aws-secrets-manager), external-dns,
#   kube-prometheus-stack
# secrets in AWS Secrets Manager: ycash/lite/ycashd-rpc {rpcuser,rpcpassword}, ycash/lite/yindex-postgres {url}
# images: docker tag + push to the ECR repositories in `terraform output ecr_repositories`
make -C ../.. eks-deploy CONTEXT=<ctx> DOMAIN=lite.example.org
```
The RDS Postgres for yindex is intentionally not in this module yet (K2); on first promotion
`yindex.postgres.enabled=true` runs it in-cluster on gp3.
