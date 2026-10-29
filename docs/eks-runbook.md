# EKS runbook — from an empty AWS account to smoke green on the public host

## In plain words

This is the step-by-step order for putting the light-wallet services on AWS: build the cloud
pieces, put the program images where the cluster can fetch them, install the services, give them
a public name and a certificate, and check that a wallet can talk to them. The same recipe runs
from a laptop (`make eks-*`, below) or, for the testnets, from the operator's private repository
by workflow buttons ([§10](#10-the-testnet-cluster-from-a-private-repository)).

The chart on AWS (plan K2). Everything below is one `make` target or one command, in the order
it has to happen: terraform → add-ons (terraform too) → ECR push → helm → DNS → smoke. Nothing
here has been applied yet (no AWS credentials in the workspace, 2026-10-09): the terraform and
the chart validate offline (`make eks-validate`, CI job `eks`), the apply is the owner's.

## 0. Prerequisites

- An AWS account with admin credentials in the environment (`aws sts get-caller-identity`
  answers), `terraform` ≥ 1.6, `aws` CLI v2, `helm`, `kubectl`, `docker`, `grpcurl`.
- A **Route53 hosted zone** for the domain the host will be in (`lite.example.org` inside
  `example.org`). The zone is the one thing terraform does not create: a zone that already
  serves a domain is never owned by a cluster's state.
- The four images built locally (`make images`): the node image is 1–2 h the first time.

## 1. Terraform (`make eks-up`)

```bash
cp infra/eks/terraform.tfvars.example infra/eks/terraform.tfvars    # region, name, domain, hosted_zone_id, acme_email
make eks-up            # terraform init + apply, then `aws eks update-kubeconfig`
```

`infra/eks` (the example root around `infra/eks/module`) creates, in one apply (`module/main.tf`,
`rds.tf`, `secrets.tf`, `networks.tf`, `addons.tf`):

| | what | why |
|---|---|---|
| VPC | `10.40.0.0/16`, 3 AZs, private + public + database subnets, one NAT gateway | the nodes sync the chain through the NAT; `single_nat_gateway=false` for 3 |
| EKS | 1.31, one managed node group `general`, 3 × `m6i.xlarge` (2–10), 100 GB gp3 roots, `enable_cluster_creator_admin_permissions` | the plan's sizes |
| IRSA | EBS CSI, Load Balancer Controller, External Secrets (scoped to `ycash/lite/*`), external-dns (the zone), cert-manager (the zone) | no static keys anywhere |
| ECR | `ycash/{ycashd,lightwalletd,yindex,web}`, immutable tags, scan on push | the Makefile pushes rev tags |
| StorageClass | `gp3`, encrypted, default, `WaitForFirstConsumer` | the chart's PVCs |
| RDS | Postgres 17, `db.t4g.small`, 20 GB gp3 (autoscales to 100), single-AZ, 3-day backups, in the database subnets, 5432 from the node security group | yindex's store; the index is derived state rebuilt in minutes |
| Secrets Manager | `ycash/lite/ycashd-rpc` `{rpcuser, rpcpassword}` (random 40 chars), `ycash/lite/yindex-postgres` `{url}` (`sslmode=require`) | the two ExternalSecrets in the chart |
| add-ons | Envoy Gateway v1.3.0 (`enableEnvoyPatchPolicy` for gRPC-web), cert-manager v1.17.1, aws-load-balancer-controller 1.11.0, external-secrets 0.17.0, external-dns 1.16.1 (`domainFilters=[domain]`, `txtOwnerId=name`, `policy=sync`), metrics-server 3.12.2, kube-prometheus-stack 70.4.1 (50 GB gp3, 15 d), then `cluster-config` (ClusterIssuer `letsencrypt-prod`, ClusterSecretStore `aws-secrets-manager`) | exactly what `values-eks.yaml` assumes |

The add-ons are `helm_release` resources rather than a documented `helm install` sequence
because the role ARNs, the VPC id, the domain and the zone flow in from terraform's own
resources instead of being copied from `terraform output`, the chart versions are pinned once
(`var.addon_versions`; `kind-up.sh` installs the same Envoy Gateway and cert-manager), and
`terraform destroy` removes them in reverse dependency order. The one known cost: the helm
and kubernetes providers authenticate to a cluster that does not exist at the first plan. The
exec auth defers until it does; if a first apply still fails at a provider, run it in two
steps: `terraform apply -target=module.eks` then `terraform apply`.

The ClusterIssuer solves ACME **DNS-01 via Route53**, not HTTP-01: the gateway serves gRPC on
443 only and has no port-80 listener for an HTTP-01 solver to answer on (cert-manager's
Gateway API solver is still experimental and would need an HTTP listener on the Gateway), the
certificate can be issued before the NLB has an address, and the zone is already written by
external-dns with the same kind of IRSA role. Switching is a one-file change
(`infra/eks/module/charts/cluster-config/templates/clusterissuer.yaml`).

Verify:

```bash
kubectl get nodes                                   # 3 Ready
kubectl -n envoy-gateway-system get pods            # envoy-gateway Running
kubectl get clusterissuer letsencrypt-prod          # READY True
kubectl get clustersecretstore aws-secrets-manager  # READY True (the IRSA role works)
terraform -chdir=infra/eks output                   # secrets, kubeconfig_command; ecr_registry and rds_endpoint show <sensitive> (they carry the account): -raw prints one
```

## 2. Images to ECR (`make eks-push`)

```bash
make images            # ycashd (../ycash6), lightwalletd (../lightwalletd-dd), yindex, web (needs yew/web/dist)
make eks-push          # docker login to ECR, tag <rev>, push; a rev already there is skipped (immutable tags)
```

The revs are the ones the Makefile derives (`YCASHD_REV`, `LWD_REV`, `YINDEX_REV`, `WEB_REV`:
the short HEAD of each tree) and `make eks-deploy` sets the same revs as image tags, so the
chart always runs exactly what was pushed from the trees at hand. The ycashd image is tagged
by its tree rev too; `values-eks.yaml`'s `6.22.0` default is overridden.

## 3. The chart (`make eks-deploy`)

```bash
make eks-deploy        # helm upgrade --install, values-eks.yaml, ECR images, the host from terraform output
kubectl -n ycash get externalsecret                 # ycashd-rpc, yindex-postgres: SecretSynced
kubectl -n ycash get pods -w                        # ycashd-0..2 start syncing mainnet (startupProbe: up to 1 h)
kubectl -n ycash get gateway ycash                  # PROGRAMMED True, ADDRESS = the NLB hostname
kubectl -n ycash get certificate ycash-tls          # READY True once DNS resolves (step 4)
```

The nodes sync the Ycash chain from the P2P network (`p2p.listen: true`, port 8833 inside the
VPC; they are not reachable inbound from the internet and do not need to be). lightwalletd and
yindex become ready behind them; the HPA (3–50) needs metrics-server. `lightwalletd.trustedProxyCidrs`
is the VPC CIDR so the limiter trusts Envoy's forwarded address — and the gateway drops a
client-supplied `x-real-ip` / `x-forwarded-for` at the edge (`gateway.trustForwardedHeaders: false`,
plan §5 A-3), which kind leaves open for `load/run.sh`.

## 4. DNS and TLS

external-dns reads `external-dns.alpha.kubernetes.io/hostname: <domain>` on the Envoy Service
(the chart sets it from `gateway.host`) and writes an A/ALIAS record for the NLB into the
zone, with a TXT ownership record. cert-manager then issues the certificate by DNS-01
(a `_acme-challenge.<domain>` TXT record it writes and removes itself).

```bash
kubectl -n external-dns logs deploy/external-dns | tail         # "Desired change: CREATE lite.example.org A"
dig +short lite.example.org                                      # the NLB's addresses
kubectl -n ycash describe certificate ycash-tls                  # Issued
```

Let's Encrypt rate limits (50 certificates per registered domain per week) are far from one
host; to rehearse, point the issuer at `https://acme-staging-v02.api.letsencrypt.org/directory`.

## 5. Smoke (`make eks-smoke`)

```bash
make eks-smoke ADDR=<a funded t-address>     # scripts/smoke.sh https://<domain>:443 (the ADDR default is kind's)
```

Green is: `GetLightdInfo`, `GetLatestBlock`, `GetYellowbackInfo`, `GetVaultInfo`, `GetChainInfo`,
`ListSets` answered, `GetAddressUtxos` routed to yindex, the gRPC-web probe HTTP 200. On
mainnet `GetYellowbackInfo` reports what the node reports: before the vault upgrade's activation
height is set (no public network has one) `YellowbackStreamer` is registered only if the node
has an attestor set, so expect `unknown service` for the four Yellowback calls until then — the
plan's acceptance for K2 is the stock service on the public host plus YEW's devnet suites
pointed at it. Then re-run `load/run.sh <domain>:443` for the plan §4 EKS row.

## 6. Day two

- **Upgrade the chart:** `make images && make eks-push && make eks-deploy` — new revs, rolling
  update; the StatefulSet rolls one node at a time, the PDB keeps one ready.
- **Rotate the RPC password:** `terraform -chdir=infra/eks apply -replace='module.eks.random_password.ycashd_rpc[""]'` (with networks: `["yb-fast"]` etc.),
  then `kubectl -n ycash rollout restart statefulset/ycash-ycashd deployment/ycash-lightwalletd deployment/ycash-yindex deployment/ycash-yindex-ingest`
  (External Secrets refreshes the Secret within `refreshInterval: 1h`; `kubectl annotate externalsecret ycashd-rpc force-sync=$(date +%s)` forces it).
- **Grafana:** `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` (admin password in Secret `kube-prometheus-stack-grafana`).
- **Scale:** `node_desired` in tfvars for nodes; `lightwalletd.autoscaling.max` for replicas; `ycashd.replicas` adds a node that syncs from scratch (hours).

## 7. Rollback

| What went wrong | Do |
|---|---|
| A chart release is bad | `helm -n ycash history ycash` → `helm -n ycash rollback ycash <rev>`; the PVCs and the Secrets are untouched |
| A node image is bad | `make eks-deploy` with the previous rev (`YCASHD_REV=<rev>`) — the rev tags stay in ECR (immutable) |
| yindex's index is wrong | `kubectl -n ycash scale deploy/ycash-yindex-ingest --replicas=0`, `psql "$url" -c 'drop schema public cascade; create schema public'`, scale back up: it re-ingests from the nodes |
| RDS is gone | `terraform apply` recreates it (new password, new url, the secret is rewritten; roll yindex); the index rebuilds |
| The certificate will not issue | `kubectl -n ycash describe challenge`; DNS-01 needs the cert-manager IRSA role on the zone: `kubectl -n cert-manager logs deploy/cert-manager` |
| An add-on upgrade broke the gateway | `var.addon_versions` back to the previous pin, `make eks-up`; the EnvoyPatchPolicy's listener path is the known fragile point (plan §6) |
| Everything | `make eks-down`: helm uninstall first (releases the NLB and lets external-dns delete the record), then `terraform destroy` — RDS (`skip_final_snapshot`) and the secrets (`recovery_window_in_days = 0`) go with it, so it is a real teardown, not a pause |

## 8. Cost (us-east-1, on-demand, 730 h/month, list prices as of 2026-10; estimate, not a quote)

| Line | Size | USD/month |
|---|---|---|
| EKS control plane | 1 cluster, $0.10/h | 73 |
| Nodes | 3 × m6i.xlarge, $0.192/h | 420 |
| EBS gp3 | 3 × 100 GB roots + 3 × 50 GB ycashd + 50 GB Prometheus = 500 GB, $0.08/GB | 40 |
| NLB | $0.0225/h + NLCU (light traffic) | 25 |
| NAT gateway | 1 × $0.045/h + ~10 GB/month processed (chain sync is a one-off few GB) | 35 |
| RDS | db.t4g.small single-AZ $0.032/h + 20 GB gp3 | 26 |
| Secrets Manager, ECR, Route53 | 2 secrets, ~3 GB images, 1 zone | 4 |
| Data transfer out | first 100 GB free, then $0.09/GB; light-wallet traffic for a second endpoint | 0–20 |
| **Total** | | **≈ 625–645** |

Variants: RDS multi-AZ (`rds_multi_az=true`) +26; three NAT gateways (`single_nat_gateway=false`)
+65; a 1-year no-upfront reservation on the three nodes −35 % on that line (≈ −150);
`m6i.large` instead of `xlarge` at the plan's measured loads would halve the node line but the
`ycashd` requests (2 CPU, 4 GB × 3) no longer fit beside lightwalletd and Prometheus on three
of them. The two nodes beyond the StatefulSet's anti-affinity (one `ycashd` per node) are the
floor: `node_min = 2` keeps the cluster alive but not the three-node pool.

## 9. Open decisions (owner)

| # | Question | Default here | The alternative |
|---|---|---|---|
| K2-1 | ACME challenge | **DNS-01 via Route53** (no port 80, issues before the NLB exists, same IRSA pattern as external-dns) | HTTP-01 with an HTTP listener on the Gateway and cert-manager's experimental Gateway API solver; no Route53 access for cert-manager |
| K2-2 | yindex's Postgres | **RDS** db.t4g.small (backups, patching and failover are AWS's; +26/month) | in-cluster StatefulSet on gp3 (`yindex.postgres.enabled=true`, as kind): −26/month, one more thing to operate; the index is derived state either way |
| K2-3 | Availability zones | **single-AZ** RDS and NAT; the nodes themselves span 3 AZs (the node group's subnets) | multi-AZ RDS (+26) and three NAT gateways (+65): survives an AZ outage without a replay |
| K2-4 | Which chain | the values say **mainnet** (`ycashd.network`) | testnet is unreachable (workspace AGENTS.md), and no public network has an activation height yet: the public host serves the stock service until one is set |

## 10. The testnet cluster from a private repository

The testnets (workspace testnet plan, Revision 3, T-20) use one cluster with a namespace per
network (`yb-fast`, `yb-slow`, `legacy`). The operator's private repository holds a root that calls
`infra/eks/module` at a pinned commit with `networks = ["yb-fast", "yb-slow", "legacy"]`, its own
backend, domain, zone, ACME e-mail and sizes, and a workflow with buttons for the cluster
(plan, apply, down) and per network (deploy, upgrade, reset, status). Per network it deploys:

```bash
helm upgrade --install lite    charts/ycash-lightwallet -n yb-fast --create-namespace \
  -f charts/ycash-lightwallet/values-eks.yaml -f charts/ycash-lightwallet/values-testnet.yaml \
  -f charts/ycash-lightwallet/values-yb-fast.yaml -f <private overlay: host, seeds, ECR images by digest>
helm upgrade --install testnet charts/ycash-testnet    -n yb-fast \
  -f charts/ycash-testnet/values-eks.yaml -f charts/ycash-testnet/values-yb-fast.yaml \
  --set seed.enabled=false -f <private overlay: peers.addnode = the EC2 seeds, images by digest>
```

- The seeds stay on EC2 (`infra/testnet-seeds`), so the networks survive the cluster being down.
  The cluster's nodes reach them as `addnode` peers on each network's port.
- yindex: one RDS instance, one database per network (`yindex_yb_fast`, …), created by the
  module's Job; every network's url uses the instance's one user (testnets of one operator, not
  tenants). A removed network's database stays until dropped by hand
  (`DROP DATABASE yindex_<network>` from a `psql` pod with the admin url in Secret
  `kube-system/yindex-db-admin`).
- A network's reset (its chain started over) also clears its index: drop and recreate the
  `public` schema of that network's database (§7, "yindex's index is wrong"), then redeploy.
- Images by digest from ghcr.io, mirrored into ECR (T-12) before the deploy; the ECR registry
  name carries the account id and is masked in the workflow's logs.
- Up for test campaigns and the rc soak, down otherwise (`eks-down`): §8 is its cost while up,
  plus one NLB per network's gateway (≈ $16–20 each, so ≈ +$35 for three over §8's one).
