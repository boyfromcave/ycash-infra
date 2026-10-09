# ycash-infra — the Ycash light-wallet backend on Kubernetes

The deployment of a scalable, non-custodial light-wallet backend for Ycash and Ycash Yellowback
(YED) on the vault network upgrade: a pool of `ycashd` full nodes, a horizontally scaled
`lightwalletd-dd`, an address index (`yindex`) that keeps per-user polling off the node, a Redis
verdict cache, and an Envoy Gateway in front that terminates TLS and transcodes gRPC-web for the
browser wallet (`yew/web`). One Helm chart, two value sets: **`kind`** (one laptop, regtest,
miner in-cluster) and **`eks`** (AWS). Nothing in this repo is cloud-specific; the EKS values
swap storage class, load balancer, DNS and secrets and nothing else.

Design and decisions: [docs/plans/ycash-infra-plan.md](docs/plans/ycash-infra-plan.md)
(ideation record: workspace `docs/ideation/yellowback-web-wallet-and-k8s-plan.md`, branch
`ideation/web-wallet`). Working rules: [AGENTS.md](AGENTS.md).

## What runs, and what is shared

Nothing is shared between replicas at any tier. The chain itself is the replicated state and the
Ycash protocol replicates it; Kubernetes only load-balances.

| Tier | Replicas | Owns | Why more than one |
|---|---|---|---|
| Envoy Gateway | 2+ | nothing | TLS, gRPC-web, rate limits, HA |
| `yindex` | 2+ (stateless) + 1 Postgres | the address → UTXO/txid index, written by one ingester | takes `GetAddressUtxos`/`GetTaddressTxids`/`GetTaddressBalance` off the node entirely |
| `lightwalletd-dd` | 3–50, HPA | its own compact-block cache (≈106 MB for all of Ycash, rebuilt in minutes) | client fan-out |
| Redis | 1 (+replica on EKS) | the tip-hash-keyed cache of `yed_*` verdicts | per-user polling becomes per-block work |
| `ycashd` | 2–5, StatefulSet, one PVC each | its own full copy of the chain, synced from the Ycash P2P network like any node | RPC read capacity, rolling restarts |

A `ycashd` cannot share a datadir (it locks it; LevelDB has one writer). The StatefulSet gives
each node a stable name and its own disk; a ClusterIP Service round-robins JSON-RPC across the
nodes whose readiness probe (synced, within one block of the best tip) passes. Any node relays a
transaction. Two nodes can disagree at the tip for a block during a reorg; the light clients'
10-block rewind already covers that and the kind suite exercises it.

Envoy routes by gRPC method: the three address methods of `CompactTxStreamer` go to `yindex`,
everything else to `lightwalletd-dd`. **No source change in `lightwalletd-dd`** and no new RPC
surface: clients still see exactly the four services of the proto
(`CompactTxStreamer`, `YellowbackStreamer`, and nothing else).

## Quick start (kind)

Prerequisites: Docker Desktop, `kind`, `kubectl`, `helm` (`brew install kind kubectl helm`),
`grpcurl` for the smoke test. The node image is built from the workspace's `ycash6` tree
(`upgrade/vault`); the first build is a full `zcutil/build.sh` and takes 1–2 h on a laptop
(depends are cached in a Docker build-cache mount afterwards).

```bash
make images        # ycashd (from ../../ycash6), lightwalletd-dd (from ../../lightwalletd-dd), yindex, web
make kind-up       # cluster + Envoy Gateway + cert-manager + the chart with values-kind.yaml
make kind-smoke    # GetLightdInfo / GetYellowbackInfo / GetVaultInfo through the gateway over TLS
make kind-load     # ghz against the gateway: the node's RPC ceiling per method (plan K1)
make kind-down
```

The kind overlay runs one regtest `ycashd` with the vault upgrade active from height 1
(`-nuparams=6d5b7a31:1`), a bootstrap Job that mines the chain past coinbase maturity, and a
miner Deployment that keeps mining one block every few seconds. Arming YED on regtest (an
attestor set created on chain, then the node restarted with `-yellowbackattestorset=<setid>`)
follows the devnet's `up` recipe and is chunk K0b in the plan; until then the Yellowback service
answers `GetYellowbackInfo` / `GetVaultInfo` / `ListSets` and the stock services are complete.

## Promotion to AWS (EKS)

```bash
cd infra/eks && terraform init && terraform apply          # the cluster, one managed node group, IRSA
make eks-deploy CONTEXT=<kubectl context> DOMAIN=lite.example.org
```

`values-eks.yaml` differs from kind in: `gp3` storage class and real PVC sizes; mainnet or testnet
node flags; the Envoy Gateway behind an NLB with a Route53 record and a cert-manager
Let's Encrypt issuer; `rpcuser`/`rpcpassword` from AWS Secrets Manager through External Secrets;
HPA 3–50 on `lightwalletd-dd`; a Redis replica; kube-prometheus-stack required. The public
`lite.ycash.xyz` endpoint stays where it is (owner decision I-8, 2026-10-08); this chart is for a
second endpoint until the owner says otherwise.

## Layout

```
images/ycashd/        Dockerfile (from the ycash6 source tree) + Dockerfile.release (from a release tarball) + entrypoint
images/yindex/        Dockerfile for yindex
yindex/               Go: the address index (ingester, Postgres store, gRPC server for the three address methods)
charts/ycash-lightwallet/   the chart; values.yaml (defaults), values-kind.yaml, values-eks.yaml
kind/kind.yaml        the kind cluster (ports 443 and 9067 mapped to the host)
scripts/              kind-up.sh, smoke.sh, wait-for.sh
load/                 ghz scenarios (plan K1)
infra/eks/            Terraform: VPC, EKS, node group, IRSA, External Secrets
docs/plans/           ycash-infra-plan.md (phases K0–K3, decisions, status)
```
