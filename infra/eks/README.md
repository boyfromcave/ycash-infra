# infra/eks — the light-wallet service stack on AWS EKS

## In plain words

The public services people use (the light-wallet server, the address index, the web wallet) run
on Kubernetes. This directory is the recipe for the AWS side of that: a private network, a
Kubernetes cluster, a database, the stored passwords the services read, and the add-ons that give
the cluster certificates and public names. The recipe is generic: the AWS account, the domain, the
DNS zone and the contact e-mail are settings the operator supplies, never written here.

It comes in two parts:
- **`module/`**, the recipe itself, which an operator's private repository calls at a fixed commit
  (the testnets' cluster is deployed that way);
- **this directory**, a small example around it, so that `make eks-up` still works from a laptop.

One cluster can serve one network (the mainnet light-wallet endpoint, as before) or several
testnets side by side, one namespace each (`networks`).

## The module

`module/` creates, in one apply: VPC, EKS (3 × m6i.xlarge), IRSA roles, ECR, the gp3
StorageClass, RDS Postgres for yindex (`rds.tf`), the Secrets Manager secrets the charts'
ExternalSecrets read (`secrets.tf`, generated, never typed) and the add-ons as `helm_release`
resources (`addons.tf`: Envoy Gateway, cert-manager + ClusterIssuer `letsencrypt-prod` by Route53
DNS-01, aws-load-balancer-controller, external-secrets + ClusterSecretStore `aws-secrets-manager`,
external-dns, metrics-server, kube-prometheus-stack; the two cluster-scoped objects are the local
chart `module/charts/cluster-config`).

- **No provider block and no backend.** The caller holds both, and configures the `kubernetes`
  and `helm` providers from the module's `cluster_endpoint`, `cluster_certificate_authority_data`
  and `cluster_name` outputs (`main.tf` here shows how).
- **Every name is a variable:** `name`, `domain` (the gateway host, or a parent of every gateway
  host), `hosted_zone_id`, `acme_email`, `secrets_prefix`, `ecr_prefix`, `cluster_admin_arns`,
  `vpc_cidr`, `tags`; the region comes from the caller's provider.
- **`networks`** (default empty): with `["yb-fast", "yb-slow", "legacy"]`, each network gets
  `<secrets_prefix>/<network>/ycashd-rpc` and `<secrets_prefix>/<network>/yindex-postgres`, the
  latter pointing at its own database `yindex_<network>` on the one RDS instance (a Job in the
  cluster creates the missing ones, `networks.tf`). The charts deploy once per network, each in
  its own namespace, with their `values-<network>.yaml`.
- **Outputs that embed the account id are sensitive** (`ecr_registry`, `ecr_repositories`,
  `irsa_roles`, `rds_endpoint`, `cluster_endpoint`): `terraform apply` and `terraform output`
  print `<sensitive>`; `terraform output -raw <name>` still returns the value to a script, which
  masks it before using it in a CI log.

```hcl
# a private root (fake values; the operator's real ones never enter this repository)
terraform {
  backend "s3" {}
}
provider "aws" { region = var.region }
module "eks" {
  source         = "git::https://github.com/<owner>/ycash-infra.git//infra/eks/module?ref=<sha>"
  name           = "ycash-testnet"
  domain         = "example.org"           # hosts lite-fast.example.org, … below it
  hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  acme_email     = "ops@example.org"
  secrets_prefix = "ycash/testnet"
  networks       = ["yb-fast", "yb-slow", "legacy"]
  ecr_images     = ["ycashd", "ycashd-legacy", "lightwalletd", "yindex", "web"]
}
provider "kubernetes" { … }   # from module.eks.cluster_endpoint etc., as main.tf here
provider "helm" { … }
```

## The example root (this directory)

```bash
cp terraform.tfvars.example terraform.tfvars      # region, name, domain, hosted_zone_id, acme_email
make -C ../.. eks-up                              # terraform init + apply + kubeconfig
make -C ../.. eks-push eks-deploy eks-smoke       # ECR, the chart, the public host
make -C ../.. eks-validate                        # offline: fmt, validate, the module test, helm template | kubeconform
```

The state is a local file here (gitignored). The order, the verification at each step, the cost
estimate and the rollback table are in [docs/eks-runbook.md](../../docs/eks-runbook.md). Not
applied yet: the workspace has no AWS credentials; everything here validates offline, and
`module/tests/networks.tftest.hcl` checks the module's own resources against mocked providers
(the upstream VPC, EKS, IRSA and RDS modules overridden): the network-less default, one secret
pair and one database per network, the database Job's hardening, the refusals.
