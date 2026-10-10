# infra/eks

One `terraform apply` from an empty account to a cluster the chart deploys onto: VPC, EKS
(3 × m6i.xlarge), IRSA roles, ECR, the gp3 StorageClass, RDS Postgres for yindex (`rds.tf`),
the two Secrets Manager secrets the chart's ExternalSecrets read (`secrets.tf`, generated, never
typed) and the add-ons as `helm_release` resources (`addons.tf`: Envoy Gateway, cert-manager +
ClusterIssuer `letsencrypt-prod` by Route53 DNS-01, aws-load-balancer-controller,
external-secrets + ClusterSecretStore `aws-secrets-manager`, external-dns, metrics-server,
kube-prometheus-stack; the two cluster-scoped objects are the local chart `charts/cluster-config`).

```bash
cp terraform.tfvars.example terraform.tfvars      # region, name, domain, hosted_zone_id, acme_email
make -C ../.. eks-up                              # terraform init + apply + kubeconfig
make -C ../.. eks-push eks-deploy eks-smoke       # ECR, the chart, the public host
make -C ../.. eks-validate                        # offline: fmt, validate, helm template | kubeconform
```

The order, the verification at each step, the cost estimate and the rollback table are in
[docs/eks-runbook.md](../../docs/eks-runbook.md). Not applied yet (2026-10-09): the workspace
has no AWS credentials; everything here validates offline.
