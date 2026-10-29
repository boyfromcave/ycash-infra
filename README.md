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
`ideation/web-wallet`). Working rules: [AGENTS.md](AGENTS.md). Part of
[Ycash vaults and Yellowback](https://github.com/boyfromcave/yellowback).

## In plain words

This repository holds the recipes for running Ycash's public services: the light-wallet backend
(the servers a phone or browser wallet talks to), the three Ycash **testnets** that rehearse the
Ycash Yellowback (YED) vault upgrade, and the build of the Ycash node's container image. Everything
here is generic: no account, domain or key that identifies an operator is in it. An operator's own
settings live in a separate, private deployment repository that uses these recipes.

| What | Where | For whom |
|---|---|---|
| The Ycash node container image, `ghcr.io/boyfromcave/ycashd` | [images/ycashd/README.md](images/ycashd/README.md) (what it is, how to run and verify it), built by `node-image` | anyone running a testnet node |
| The three testnets: testnet-yb-fast, testnet-yb-slow, testnet-legacy | [The testnets](#the-testnets) below | testers, operators |
| The light-wallet backend on Kubernetes (kind on a laptop, EKS on AWS) | [Quick start (kind)](#quick-start-kind), [Promotion to AWS (EKS)](#promotion-to-aws-eks) | developers, operators |
| Published bundles: the Zcash testnet history (`testnet-prefix-v1`) and the Zcash parameters (`zcash-params-v1`) | [Releases](https://github.com/boyfromcave/ycash-infra/releases), `bundles/` | node operators |
| The owner's public signing key for release checksums | [keys/README.md](keys/README.md) | anyone verifying a download |

## The testnets

Three practice networks with worthless coins, all built from Zcash's testnet history up to block
510,247 (harvested and published reproducibly by `testnet-prefix.yml`) and split at block 510,248,
where Ycash itself forked:

| Testnet | Rehearses | Node flag | P2P / RPC ports |
|---|---|---|---|
| testnet-yb-fast | Yellowback with its waiting periods shortened (set and bond maturity 48 blocks) | `-testnet -testnetprofile=fast` | 18833 / 18832 |
| testnet-yb-slow | Yellowback with mainnet's values; the activation itself is rehearsed live | `-testnet -testnetprofile=slow` | 18933 / 18932 |
| testnet-legacy | today's Ycash rules, no upgrade: the control network | `-testnet -testnetprofile=legacy` | 19033 / 19032 |

- **Seed nodes** (always on, fixed addresses): `infra/testnet-seeds`, Terraform for EC2 + Elastic
  IPs. Each host serves all three networks; deploy, upgrade, reset and status per network.
- **Services** (light-wallet backend per network, on demand): `infra/eks/module` plus
  `charts/ycash-lightwallet` and `charts/ycash-testnet`, one namespace per network. The testnet chart
  also carries, per network and behind values flags, the **faucet** (`images/faucet`, testnet mode;
  needs the owner's T-9), the **probe and status page** (`images/testnet-status`), the **snapshotter
  and bundle verifier** (state bundles, `bundles/state/FORMAT.md`) and the **alerts**
  (kube-prometheus-stack): [charts/ycash-testnet/README.md](charts/ycash-testnet/README.md#the-services).
- **The plan:** workspace `docs/plans/yellowback-testnet-plan.md`.

## Node line: `upgrade/vault`, post-quantum

The `ycashd` image is built from the workspace's `ycash6` tree as checked out, which is
`upgrade/vault` (`make images`; `YCASH6=` points elsewhere). The post-quantum line
(`upgrade/quantum-vaults`) has been merged into `upgrade/vault`, so those nodes answer
`yed_getinfo` with `rpcversion` 8 (post-quantum owners and the fee rules), and so does
`lightwalletd-dd` built from its `upgrade/vault`. The chart assumes that line:
`ycashd.rpcVersion` defaults to 8 and the arming Job refuses any other node (`--set
ycashd.rpcVersion=6` for an `upgrade/vault` tree from before the merge). `yindex` indexes the
post-quantum address forms (below), and the regtest arming Job creates the attestor set at the
YED module's `BOND_MATURITY` (8 on regtest), above the post-quantum line's floor of 2.

**No smoke test** has yet been recorded running this chart against post-quantum nodes.

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

`yindex` takes every transparent address form the post-quantum node line renders or accepts:
`s1…`/`sm…` P2PKH and P2SH, YED `yb…`/`yt…`/`yr…` (35 characters, mapped to the transparent
twin), plain-YEC post-quantum `sq…`/`tq…`/`rq…` (53 characters: a `TX_PQPKH` output,
`20 <SHA256(scheme‖pk)> 51|52 c2`, D-Q-20) and post-quantum YED `yb…`/`yt…`/`yr…` (53 characters,
mapped to the `sq…`/`tq…`/`rq…` form of the same script). The old mainnet YED prefix `ye…` is
refused, as the post-quantum node refuses it (D-Q-21). `lightwalletd-dd`'s own taddr methods
accept the same forms when it serves `--yellowback` (`frontend/service.go` `taddrOf`,
`checkTaddress`), but the five address methods stay in `yindex.routes` so that address queries are
answered from the index and never reach the node.

## Quick start (kind)

Prerequisites: Docker Desktop, `kind`, `kubectl`, `helm` (`brew install kind kubectl helm`),
`grpcurl` for the smoke test. The node and lightwalletd-dd images are built from the workspace's
main repo dirs `../ycash6`, `../ycash-dd` and `../lightwalletd-dd` (override `YCASH6=`, `YCASH_DD=`,
`LWD=`), on the branch `BRANCH` names (default `upgrade/vault`; `LINE=quantum` is shorthand for
`BRANCH=upgrade/quantum-vaults`, `LINE=vault` for `upgrade/vault`). `make line` checks that each
tree's HEAD contains `BRANCH` and that ycashd and lightwalletd-dd speak one rpcversion
(`RPC_VERSION=8` requires it), and prints it. lightwalletd-dd matches the node's
`yed_getinfo.rpcversion` exactly, and the chart's arming Job refuses a node whose rpcversion is not
`ycashd.rpcVersion` (default 8, the post-quantum line; `--set ycashd.rpcVersion=6` for an
`upgrade/vault` tree from before the post-quantum merge). The node image needs
`contrib/docker/ycashd/` (K0a) in the node tree; the first build is a full `zcutil/build.sh` and
takes 1–2 h on a laptop (depends are cached in a Docker build-cache mount afterwards).

```bash
make images        # ycashd + lightwalletd-dd (from the BRANCH's trees), yindex, web, faucet; again after a chart change that needs it
make demo          # the demo kit: cluster, images, mkcert certificate, Grafana, the chart; prints the URLs (docs/try-it.md)
make kind-up       # cluster + Envoy Gateway + cert-manager + the chart with values-kind.yaml
make kind-smoke    # GetLightdInfo / GetYellowbackInfo / GetVaultInfo / GetChainInfo / ListSets through the gateway over TLS
make kind-parity   # yindex vs lightwalletd's node-proxied answers for every address the chain touched (plan K3)
make kind-load     # ghz against the gateway: the node's RPC ceiling per method (plan K1)
make kind-down
```

A chart change can need rebuilt images (the hardened chart's read-only root filesystem crash-loops a
`web:local` built before its pid file moved to `/tmp`), and kind reuses any `:local` image: every
`make image-*` labels its image with a hash of its Dockerfile and the files it copies in, and
`make kind-load` (so `kind-up` and `demo`) refuses an image whose label differs from the tree, naming
the `make image-…` to run (`make image-check` alone; `ALLOW_STALE_IMAGES=1`, or `=ycashd,web` by name,
to go on). `kind-up` fails unless every Deployment and StatefulSet rolls out (`ROLLOUT_TIMEOUT=10m`
each) and no pod is failing.

The kind overlay runs one regtest `ycashd` with every upgrade through Canopy plus the vault
upgrade active from height 1 (the seven `-nuparams` the devnet uses; the light clients' regtest
parameters assume exactly that chain) and Falcon admitted from it (`-pqfalcon=1`, as on mainnet), a bootstrap Job that mines the chain past coinbase maturity, and a
miner Deployment that keeps mining one block every few seconds, and (`regtest.armYellowback`)
the arming Job: the devnet's `up` recipe for one node — `set_create` the YED attestor set from
the node's wallet (OPEN, 15 seats, maturity = the YED module's `BOND_MATURITY`: 8 on regtest,
48 on testnet-yb-fast, 16,128 on mainnet and testnet-yb-slow — the node refuses a set below its
network's minimum (2 on regtest), D-Q-31, and the module adopts only that value; `regtest.attestorSet.maturity` overrides and the render fails on
either mistake), mine it, record its id in ConfigMap `ycash-yellowback-set` (the StatefulSet's
`YCASHD_YELLOWBACK_ATTESTOR_SET`) and one attestor key in Secret `ycash-yellowback-attestor`,
restart the node, wait for `yed_getinfo` and check its `rpcversion` against `ycashd.rpcVersion`, roll lightwalletd (it probes `yed_getinfo` at startup).
After it, `GetYellowbackInfo` reports `upgrade.status: active` and `attest.status: UNARMED`
(no attestors are registered yet). The Job is idempotent, and
`kubectl -n ycash logs -l app.kubernetes.io/component=arm-yellowback --all-containers` shows what it did.

### YED for real: attestors, prices, pool quotes (K0c)

```bash
make kind-personas-up      # the node as the quoting pool (one helm upgrade), yellowback-quote, 3 attestors, attest/subscribe agents, the price walk
make kind-personas-status  # attest ARMED? the price, the mint gate, a $100 estimate
make kind-personas-down    # stop the agents; the chain stays ARMED
```

`scripts/kind-personas.py` runs the devnet's own agents from the workspace (`ycash6/contrib/yellowback`:
the Rust `yellowback-attest`, built with `cargo build --locked --release` in its crate, and the Python
`yellowback-quote` under the workspace venv) against the node's host port 18832; the chart's miner is
the heartbeat and every block it mines carries the node's quote tag. State, configs, logs and the
attestation bus: `~/.local/state/ycash-infra/personas`. After it `yed_getinfo` is `ARMED` with a
price and `mint_availability` lists classes A, B, C; the web wallet mints, sends and redeems YED
(`yew/web/scripts/test-web-smoke.sh --kind --mint https://localhost/`). The arming sequence, RPC by
RPC: plan §1.2. A `helm upgrade` from a chart without K0c's payout lookup restarts the node without
its pool flag; `make kind-personas-up` again puts it back (it is resumable).

### The demo kit (`make demo`)

`make demo` is the kind cluster as a thing a person tests in a browser: idempotent, it creates
the cluster if needed, loads the images (the wallet bundle is built from the workspace's
`yew/` tree, or `YEW=` a worktree), installs a certificate for `localhost` from
**mkcert**'s local CA as the gateway's TLS Secret (`make kind-cert`; `mkcert -install` puts
that CA into the **system trust store**, a password prompt once; without mkcert the self-signed
certificate stays and Chrome warns), installs kube-prometheus-stack (`MONITORING=1`, the
default for `demo`) with Grafana at `/grafana/` on the gateway and the chart's dashboard
(lightwalletd gRPC rate/latency and the `yed_*` cache, yindex lag, the node RPC probe), and
applies the chart with the **faucet** on: `regtest.faucet.enabled` (regtest only) runs
`images/faucet` — `yew/web/scripts/fund-helper.py`'s logic as a Deployment speaking JSON-RPC to
the RPC Service — behind the gateway at `https://localhost/faucet/` (same origin as the wallet):
a page (paste an address → Send 2 YEC, public or private by prefix; Mine 1 block; the node's
address; the tip), the helper's routes (`/send`, `/fund`, `/fund_t`, `/address`, `/mine`,
`/reorg`), one acting request per 5 s, and the Sapling proving files at `/faucet/params/`
from a PVC an init container fills once (download.z.cash, SHA-256 checked) for the wallet's
Settings source field. The tester's guide, screen by screen: [docs/try-it.md](docs/try-it.md).

### Troubleshooting

- **Every `docker pull` / `kind create` hangs** on macOS in a non-interactive shell: Docker
  Desktop's keychain credential helper is waiting for a GUI prompt. Run with a credential-free
  config that keeps the plugins and contexts: `make docker-noauth` prints the `export` line
  (it writes `~/.docker` minus `credsStore` into a scratch dir and symlinks `cli-plugins`,
  `contexts` and `buildx` into it).
- **`helm upgrade` says another operation is in progress**: a previous `kind-up.sh` (`--wait`)
  is still running or was killed; `helm rollback ycash <last good revision>` or
  `helm uninstall ycash -n ycash` and run `make kind-up` again.
- **Resetting the regtest chain** (after changing `ycashd.extraArgs`): `make kind-reset-chain` deletes
  the node and Postgres volumes, the recorded attestor set and the one-shot Jobs, then re-runs the
  chart; the bootstrap and arming Jobs rebuild everything in a few minutes.
- **`YellowbackStreamer` is "unknown service"**: the node only registers `yed_*` once an
  attestor set exists and lightwalletd probes for it only at startup; check
  the arming Job (`-l app.kubernetes.io/component=arm-yellowback`) finished and roll `deployment/ycash-lightwalletd` if it started before
  the node was armed.
- **`kind load docker-image` fails with `ctr: content digest ... not found`** for a multi-arch
  image pulled with `--platform` (the kubectl image): the kind nodes pull from Docker Hub
  themselves, so leave it to `pullPolicy: IfNotPresent` or `docker exec ycash-worker crictl pull`.
- **`load/run.sh` reports mostly `local_rate_limited` / `ResourceExhausted`**: from one IP the
  gateway's per-IP limit and lightwalletd's Yellowback bucket are the ceiling; see the script's
  header and plan §4.

## Promotion to AWS (EKS)

```bash
cp infra/eks/terraform.tfvars.example infra/eks/terraform.tfvars   # region, domain, hosted zone, ACME email
make eks-up            # terraform: VPC, EKS, IRSA, ECR, RDS, Secrets Manager, the add-ons (one apply)
make eks-push          # the four images to ECR at their revs
make eks-deploy        # the chart with values-eks.yaml; external-dns writes the record, cert-manager issues
make eks-smoke         # scripts/smoke.sh against https://<domain>
make eks-down          # helm uninstall + terraform destroy
```

Step by step, with the cost estimate and the rollback table: [docs/eks-runbook.md](docs/eks-runbook.md).
`make eks-validate` (CI job `eks`) checks all of it offline: `terraform validate` and the EKS
render through kubeconform with the CRD schemas.

`values-eks.yaml` differs from kind in: `gp3` storage class and real PVC sizes; mainnet or testnet
node flags; the Envoy Gateway behind an NLB with a Route53 record and a cert-manager
Let's Encrypt issuer; `rpcuser`/`rpcpassword` and the RDS url from AWS Secrets Manager through External Secrets;
HPA 3–50 on `lightwalletd-dd`; the plaintext listener off; client-supplied forwarding headers
dropped at the edge (plan §5 A-3); kube-prometheus-stack required. The public
`lite.ycash.xyz` endpoint stays where it is (owner decision I-8, 2026-10-08); this chart is for a
second endpoint until the owner says otherwise.

## Layout

```
images/ycashd/        the published ycashd image's page (README); the image is built from the node tree's own contrib/docker/ycashd/Dockerfile
images/yindex/        Dockerfile for yindex
images/web/           Dockerfile + nginx.conf for the yew/web bundle (K4)
images/faucet/        the faucet: regtest (kind demo) and testnet modes, faucet.py (JSON-RPC, the pages, /params/), fetch-params.py (the init container), its README
images/testnet-status/ a testnet's probe (nodes, seeds, state hashes -> /metrics) and public status page, its README
yindex/               Go: the address index (ingester, Postgres store, gRPC server for the three address methods)
charts/ycash-lightwallet/   the chart; values.yaml (defaults), values-kind.yaml, values-eks.yaml, values-testnet.yaml (over values-eks.yaml), values-{yb-fast,yb-slow,legacy}.yaml (one release per testnet); gateway.extraListeners puts the testnet faucet and status hosts on its gateway
charts/ycash-testnet/       the testnets' network roles: ycash6 seeds, the ycash-dd verifier, the prefix restore, and per network the faucet, probe, status page, snapshotter and alerts (flags); values-{yb-fast,yb-slow,legacy}.yaml; not yet run on a cluster (its README)
kind/kind.yaml        the kind cluster (ports 443 and 9067 mapped to the host)
scripts/              kind-up.sh, demo.sh + kind-cert.sh (the demo kit), smoke.sh, parity.sh (K3), kind-personas.py (K0c), wait-for.sh
load/                 ghz scenarios (plan K1)
infra/eks/            Terraform: module/ (VPC, EKS, node group, IRSA, ECR, RDS, Secrets Manager, the add-ons as helm_release; one namespace per network) and a thin example root
infra/testnet-seeds/  Terraform: the seed hosts on EC2 + Elastic IPs (ips/, nodes/), every testnet on each host, seedctl (its README)
bundles/prefix/       the Zcash testnet history bundle: format (FORMAT.md), harvest, import checks (testnet-prefix*.yml)
bundles/state/        the testnet state bundle: format (FORMAT.md, ycash-state/1), verify.py, the snapshotter's offline tests
bundles/zcash-params/ the mirrored Zcash parameter files' checksums (zcash-params.yml)
.github/workflows/    ci, the security scans, node-image (the ycashd image), testnet-prefix(-import), zcash-params
keys/                 public keys only: ycash-release.pub, the owner's minisign key for release SHA256SUMS (its README)
docs/eks-runbook.md   EKS: empty account → smoke green, cost, rollback, open decisions
docs/try-it.md        the tester's guide to the demo kit (the wallet's screens, the walk, troubleshooting)
docs/plans/           ycash-infra-plan.md (phases K0–K4, decisions, status)
```
