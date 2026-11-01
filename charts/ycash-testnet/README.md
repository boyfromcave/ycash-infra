# charts/ycash-testnet — the Ycash testnet's network roles

## In plain words

The Ycash testnet is a public practice network where Ycash Yellowback (YED) and the vault upgrade
can run for weeks with worthless coins before anything reaches mainnet. A network needs a few
always-on computers that new participants can find and download the chain from ("seed nodes"),
and someone running the older Ycash node software alongside, to prove that both versions agree on
every block ("the cross-line verifier"). This chart describes those computers for Kubernetes, so
they can be started the same way on a laptop (kind) and in the cloud (AWS EKS).

There are three testnets (testnet-yb-fast, testnet-yb-slow, testnet-legacy), and this chart is
installed once per network (`values-{yb-fast,yb-slow,legacy}.yaml`). The node programs know all
three since the testnet profiles merged (N1). Per network it can also run the services people see:
a faucet that hands out free testnet coins, a public status page, a "snapshotter" that packs a
checked copy of the chain for fast starts, and alerts for the operators ([The services](#the-services)).
The chart is checked and rendered in CI but has not yet run on a cluster. By default it holds no
keys of any kind; the faucet, which spends a testnet wallet, is refused until the owner's T-9 rule
change is in force.

Plan: workspace `docs/plans/yellowback-testnet-plan.md` (§2.3 who runs what, §4.0 the prefix,
§6 this environment); this repository's `docs/plans/ycash-infra-plan.md` K5–K7.

## What it runs

| Role | Kind | Image | Notes |
|---|---|---|---|
| `seed` | StatefulSet, 3 replicas | `ycash6` (`images.ycashd`) | `podAntiAffinity` by zone (required on EKS, preferred by hostname on kind); a PVC per pod; P2P 18833 through **one Service per pod** (`seed.p2pService`: an internet-facing NLB per seed on EKS, NodePort 31833–31835 on kind), not-ready pods still published |
| `verifier-dd` | StatefulSet, 1 replica | `ycash-dd` (`images.ycashdLegacy`) | The cross-line verifier: syncs from the seeds over P2P. Its Sprout/Sapling parameter files on their own PVC (`verifierDd.zcashParams`), filled by the `zcash-params` init container (below) |
| `prefix-fetch`, `prefix-frame` | init containers on both, **off by default** | the node image; the future framer image | below |
| `faucet-node`, `faucet` | StatefulSet (1) + Deployment (1), **off by default**, T-9 | `ycash6`; `images.faucet` | [The services](#the-services) |
| `probe`, `status` | Deployments (1 each), on by default on kind, off in `values-eks.yaml` until their image is published | `images.status` | [The services](#the-services) |
| `snapshotter` | CronJob, **off by default** | `ycash6`, `ycash-dd`, `images.awsCli` | [The services](#the-services) |
| alerts | PrometheusRule (`monitoring.alerts`) and ServiceMonitor (`monitoring.serviceMonitor`) | — | [The services](#the-services) |

Every node role (seed, verifier-dd and, with the faucet, its wallet node) renders from one template
(`templates/node.yaml`, the roles listed by `yt.roles`); everything that differs is a value (AGENTS.md
rule 2). Each pod:
- writes `ycash.conf` through the node image's own entrypoint (`contrib/docker/ycashd/entrypoint.sh`
  in both node trees) with `testnet=1` and `testnetprofile=<p>` (the chart passes the profile as
  `YCASHD_TESTNET_PROFILE`, which the entrypoint requires on testnet);
- answers RPC on 18832 with the release's own credentials (Secret, or an ExternalSecret on EKS),
  reachable only inside the cluster through `<release>-<role>-rpc` (ClusterIP);
- gets its per-pod arguments from `files/run.sh`: its `-externalip` by ordinal
  (`<role>.externalAddresses`), `-addnode` for the other seeds by their headless-Service names
  (`peers.inCluster`), and the prefix's `-loadblock` files until the import is done.
- runs with `-maxtipage=999999999` on a testnet, so a pod restarted while the chain has been
  quiet for over a day still serves headers and block templates (`images/ycashd/README.md`,
  "Keeping a quiet testnet alive").

`peers.addnode` (written as `addnode=` lines) holds the EC2 seed hosts' addresses
(`infra/testnet-seeds`) when the operator's deployment sets it; `peers.dnsseed` stays off: the
testnets have no DNS seed, only fixed seeds (decision D1).

`network` must be `testnet`: any other value fails the render (plan §6.1).

Hardening follows `charts/ycash-lightwallet` (`SECURITY-CI.md`; Checkov scans both renders). Every
pod runs non-root as uid 2001, the node images' own user (`podUid`), with RuntimeDefault seccomp and
no service-account token. Every container, the init containers included, has no privilege
escalation, all capabilities dropped and a read-only root filesystem (`containerSecurityContext`),
plus resources. What a container writes is a mount: the datadir (PVC), `/tmp` (emptyDir; ycash-dd's
`fetch-params.sh` keeps its lock there), `$HOME` `/srv/ycash` (emptyDir; `ycash-cli` and `wget`
dotfiles) and, on the verifier, `/srv/ycash/.zcash-params` (PVC). Init containers carry no probes
(Kubernetes allows none on them). Two Checkov checks are accepted on the StatefulSets by annotation,
with the reasons there: CKV_K8S_40 (uid 2001 is the image's, so a higher one needs a node-image change)
and CKV_K8S_11 (CPU is requested, never limited, so CFS throttling cannot stall a node).

The NetworkPolicy (`networkPolicy.enabled`, on by default) admits P2P from anywhere and RPC only
from this release's pods and `networkPolicy.rpcFrom`; egress stays open. `charts/ycash-lightwallet`
has no NetworkPolicy yet (its semgrep ledger records one as a hardening lead), so this is the first;
it follows that chart's labels and port names.

## The Zcash parameter files (the verifier)

In plain words: ycash-dd will not start without three public Zcash files (about 777 MB). Before the
verifier's node starts, a small init container downloads them once from this repository's GitHub
release and checks each against a fingerprint written into the chart; a file that does not match
is thrown away and the node does not start.

Every role with `zcashParams.enabled` (by default only `verifierDd`; ycash6 compiles the parameters
in) gets the `zcash-params` init container (`files/zcash-params.sh`, in the role's own image). It
fetches `sapling-spend.params`, `sapling-output.params` and `sprout-groth16.params` whole from
`zcashParams.url` (default
`https://github.com/boyfromcave/ycash-infra/releases/download/zcash-params-v1`, the mirror
`bundles/zcash-params/README.md` describes) into the params PVC, `https://` only, and refuses unless
each matches `files/zcash-params.SHA256SUMS`: a byte-identical copy of
`bundles/zcash-params/SHA256SUMS`, which copies the sums ycash-dd's `zcutil/fetch-params.sh:223-225`
pins (`make zcash-params-test` checks both). A file already there that checks is kept; one that does
not is fetched again. The image's entrypoint then finds the files and skips its own
`fetch-params.sh` run. The container runs under the same hardening as the node (read-only root,
the `/tmp`, `$HOME` and params mounts) with `zcashParams.resources`. `download.z.cash` serves each
file as two parts, so it is not a drop-in `zcashParams.url`; any other host holding the three whole
files is, since the sums, not the host, are what is trusted.

## The prefix restore (off by default)

The testnet is Zcash testnet's history to block 510,247 and a new Ycash fork after it; the history
below the fork is not on the testnet's P2P network from the start, so a first node imports it from
the **prefix bundle** (format `ycash-prefix/1`, `bundles/prefix/` in this repository).

With `prefixRestore.enabled`:
1. `prefix-fetch` (`files/prefix-restore.sh`, in the node image: sh, curl, sha256sum, jq) runs only
   on an **empty datadir**. A datadir with anything but `lost+found` and a partial `prefix/` is left
   alone and the node starts from what it has.
   - It downloads `SHA256SUMS` from `prefixRestore.baseUrl` and **refuses unless its sha256 equals
     `prefixRestore.sha256sums`**, the pin in the values.
   - It downloads `manifest.json` and every chunk listed, and refuses unless every file checks.
   - It refuses unless the manifest is `ycash-prefix/1`, `zcash-testnet`, heights
     0..`prefixRestore.lastHeight`, with the same chunk set and hashes as `SHA256SUMS`.
   - A file that fails is deleted, so the pod's restart fetches it whole.
2. `prefix-frame` (`images.prefixFrame`) turns the magic-neutral chunks (`<LE u32 len><block>`)
   into `-loadblock` files (`<magic><LE u32 len><block>`, magic `prefixRestore.magic`).
   - This is `bundles/prefix/import/frame.py`, packaged as an image. **That image does not exist
     yet**: the render fails if the restore is enabled without it.
   - `prefixRestore.frameCommand` is an assumed CLI, to align with frame.py once it is written.
3. The node starts with `-loadblock` for each framed file. The readiness probe marks the import done
   at `lastHeight`, and the next start drops the flag and the framed copies.

The node validates every imported block. Below the compiled checkpoints it skips only what
checkpoints skip (plan §4.0). The state bundle is produced by the snapshotter below
([The services](#the-services)); restoring one is `ycash-bootstrap`'s (plan §4.4, N2).

## The services

In plain words: the seeds and the verifier keep a testnet alive; these are what people and operators
use on top of it, one set per network. Each is a values flag, so a network gets exactly the ones its
deployment turns on.

### The faucet (`faucet`, off by default; needs T-9)

`images/faucet` in `FAUCET_MODE=testnet` ([its README](../../images/faucet/README.md)) pays a fixed
amount of testnet YEC (`faucet.amountZat`, 1 YEC) to a transparent or Sapling address of this network,
never YED. Limits: per client IP (`faucet.perIp`, IPv6 per /64, from the gateway's `X-Forwarded-For`),
per address (`faucet.perAddress`), a rolling 24 h cap (`faucet.dailyCapZat`), one payment at a time
(`faucet.rateSeconds` apart), a proof-of-work challenge the page solves (`faucet.powBits`, 16 bits), and
an Envoy limit on its route (`faucet.route.requestsPerSecond`). It has no mining, reorg or node-address
route, and serves the Sapling proving files only with `faucet.params.enabled` (off: testnet wallets
fetch them from their usual source). It refuses to pay unless its node reports chain `test` and this
network's profile.

It pays from its own wallet node, `<release>-faucet-node` (ycash6, one replica, `faucet.node`, a role of
`templates/node.yaml`): the node restores its wallet from the recovery phrase in Secret
`faucet.wallet.existingSecret` (key `mnemonic`), mounted as a file and passed as `-mnemonicfile` by the
node image's entrypoint (`YCASHD_MNEMONIC_FILE`); the phrase never reaches the faucet process or a
values file. With External Secrets, `faucet.wallet.remoteKey` names it in the store
(`ycash/testnet/<network>/faucet-wallet`, created by hand per network, never by Terraform). The wallet
node takes no inbound P2P (`-listen=0`) and its RPC only from the faucet pod (NetworkPolicy
`<release>-faucet-node`). Fund it by sending testnet YEC to its first Sapling address
(`z_listaddresses` on the node); the faucet shields the wallet's coinbase first if a miner pays to it.

**T-9.** `AGENTS.md` rule 4 says nothing in the cluster holds a spending key. Decision T-9 (owner,
2026-10-29; plan §6.1, §8) amends it for this chart only: testnet-only keys (the faucet wallet's
recovery phrase, the snapshotter's GitHub token), from External Secrets, never in a values file or
git, never on mainnet. The faucet and the GitHub token still render only with
`testnetKeys.allowed: true`, the deployer's explicit opt-in for that network; without it the render
fails with the reason.

The route: the faucet's own host (`faucet.route.host`, `faucet-fast.example.org` etc. in the network
values, placeholders until T-3) on the lightwallet release's gateway in the same namespace
(`faucet.route.gateway`, default `lite`), listener `https-faucet`. That listener is the lightwallet
chart's `gateway.extraListeners` entry `{name: faucet, host: …}` (its own certificate; external-dns
writes the record). The route passes the page's exact paths only, so `/metrics` stays inside.

### The probe and the status page (`probe`, `status`)

`images/testnet-status` ([its README](../../images/testnet-status/README.md)). The **probe** asks every
node of the network over RPC (this release's seeds and verifier, the lightwallet release's nodes,
`probe.lightwallet`, and `probe.extraNodes`), checks every seed over P2P in this network's magic
(`probe.seeds`, host:port; the EC2 seed hosts on the testnet cluster, the in-cluster seeds otherwise),
reads the latest bundle's manifest (`probe.bundleManifestUrl`) and serves `/metrics` and a public
summary inside the cluster. The **status page** shows height, last block, peers, the vault upgrade's
height and state, the attestor set id, the release (`status.release`), the node version, the latest
bundle and the operator's notices (`status.notices`, e.g. a reset). It holds no secret and reaches no
node, only the probe; its route (`status.route`, host `status-<network>.example.org`, listener
`https-status`) is off until the host exists. On kind both run from `make image-testnet-status`; in
`values-eks.yaml` both are off until the image is published by digest.

### The snapshotter and bundle verifier (`snapshotter`, off by default)

A CronJob (`snapshotter.schedule`, daily) that makes a state bundle per [bundles/state/FORMAT.md](../../bundles/state/FORMAT.md)
(plan §4.1-§4.3), one step per container of one pod (`files/snapshot.sh`):

1. `pick`: `H_B` = the last multiple of 1,440 at least 1,000 blocks below the reference node's tip
   (`snapshotter.referenceRpc`, default this release's verifier), or `snapshotter.height`; nothing to do
   when it is not above the last bundle.
2. `produce`: a ycash6 node on its own volume (`<release>-snapshot-src`, kept between runs) syncs from
   the peers with `-stopatheight=H_B` and stops there; its datadir is packed (sorted tar, fixed times
   and owners, `gzip -n`).
3. `restore-check`: the tarball is extracted into an empty datadir and started offline; its state at
   `H_B` is the ycash6 statement.
4. `verify-dd`: a ycash-dd node on its own volume (`<release>-snapshot-dd`) syncs to `H_B` the same way:
   the independent statement (plan §4.2; `snapshotter.verifierDd`).
5. `finalize`: the statements must be byte-identical, then `manifest.json` and `SHA256SUMS`.
6. publish, both off by default: `snapshotter.publish.s3` (bucket, prefix, an IRSA role, no secret) and
   `snapshotter.publish.github` (a draft release with the manifest, `SHA256SUMS` and the statements;
   a token from a Secret, under T-9).

A run before an rc: `helm upgrade … --set snapshotter.height=<H_B>`, then `kubectl -n <network> create
job --from=cronjob/<release>-snapshotter rc-bundle`. Signing `SHA256SUMS` (T-6, the owner's key) happens
in the private deployment, not here. The first run syncs the chain twice (both lines), within
`snapshotter.activeDeadlineSeconds` (12 h); later runs sync only the new blocks.

### The alerts (`monitoring`)

`monitoring.alerts.enabled` renders a PrometheusRule per network (labelled for kube-prometheus-stack's
rule selector, `monitoring.alerts.labels`), from the probe's metrics, kube-state-metrics and the
kubelet's volume stats (plan §6.4):

| Alert | When |
|---|---|
| `YcashTestnetTipStale` | a node's tip is older than 15 min (`tipAgeSeconds`) |
| `YcashTestnetNodeDown`, `YcashTestnetProbeDown` | a node does not answer RPC; the probe stops reporting |
| `YcashTestnetPeersLow` | a node has fewer than 4 peers (`minPeers`) |
| `YcashTestnetTipsDisagree` | the nodes hold different blocks at their common height |
| `YcashTestnetForkLong` | a side branch near the tip longer than 2 blocks (`forkBlocks`) |
| `YcashTestnetStateHashDivergence` | `vault_getinfo.statehash` or `yed_getstatehash` differs between nodes at the same block: the cross-line verifier disagreeing (G-10) |
| `YcashTestnetSeedUnreachable` | a seed does not answer a P2P version message in this network's magic |
| `YcashTestnetBundleStale`, `YcashTestnetSnapshotterStale`, `YcashTestnetSnapshotterFailed` | the latest bundle, or the snapshotter's last success, is older than 3 days; a snapshotter run failed |
| `YcashTestnetDiskLow` | a volume in the namespace has less than 15 % free |
| `YcashTestnetFaucetLow`, `YcashTestnetFaucetWrongChain` | the faucet holds less than 10 YEC; its node is not on this network |

`monitoring.serviceMonitor` has Prometheus scrape the probe and the faucet. The alerts need the probe.

### Turning them on (EKS)

`values-eks.yaml` keeps every service off, so a deployment that sets only the node images renders
what it rendered before. A deployment turns them on per network, e.g.:

```bash
helm upgrade --install testnet charts/ycash-testnet -n yb-fast -f values-eks.yaml -f values-yb-fast.yaml -f <private overlay> \
  --set probe.enabled=true --set status.enabled=true --set status.route.enabled=true --set monitoring.alerts.enabled=true \
  --set images.status.repository=<registry>/testnet-status --set images.status.digest=sha256:… \
  --set 'probe.seeds={<seed-1>:18833,<seed-2>:18833}' --set status.route.host=status-fast.<domain>
# and on the lightwallet release: gateway.extraListeners=[{name: status, host: status-fast.<domain>}] (and faucet)
```

`ci/services-values.yaml` turns every service on with placeholders for CI (`make lint-testnet`,
`scripts/lint-images.sh`, Checkov); it is not a deployment's values.

## What it deliberately leaves out

| Not here | Why | Waits for |
|---|---|---|
| `miner` (`-gen -mineraddress`) | not planned: the testnets' blocks come from GPU miners rented on Vast.ai (owner, 2026-11-01; `infra/vast-miners/README.md`); slow and legacy need about 109 Sol/s at Equihash 192,7, far beyond a CPU | — |
| `pool` (yolo), the stratum endpoint those miners use | a payout address; where the pools run (the seed hosts or this chart) is open | T-9 (the `AGENTS.md` rule 4 amendment for this chart) |
| `attestor` (house seats), `bridge-persona` | hold signing keys | T-9, T-5 (the founding set) |
| `dnsseed` | the testnets have fixed seeds only (D1) | — |
| statement signatures, `SHA256SUMS` signing | keys | T-6 (the private deployment signs), T-9 (verifier keys) |
| a published `faucet` and `testnet-status` image | no workflow builds them yet | the release images work (T-12) |

By default nothing in this chart holds a seed, a spending key or a payout address, and
`rpcuser`/`rpcpassword` are the only secrets, the nodes' own (`AGENTS.md` rule 4). The faucet's wallet
and the snapshotter's GitHub token are the exceptions, and only behind `testnetKeys.allowed` (T-9).

## Values

- `values.yaml`: defaults, every key documented.
- `values-kind.yaml`: renders for kind. Images `ycash/ycashd:local` and `ycash/ycashd-legacy:local`
  (`make image-ycashd image-ycashd-legacy`), 5 Gi PVCs, NodePort P2P, a kind-only RPC credential.
- `values-eks.yaml`: renders for EKS: gp3, an NLB per seed, External Secrets
  (`ycash/testnet/ycashd-rpc`; per network the overlay below names that network's secret, which
  `infra/eks/module` makes with `networks`).
- `values-yb-fast.yaml`, `values-yb-slow.yaml`, `values-legacy.yaml`: **the three testnets**
  (workspace testnet plan, Revision 3, T-14), one release per network over the kind or EKS values.
  Each sets only what differs: `testnetProfile` (written into `ycash.conf` as
  `testnetprofile=<p>` beside `testnet=1`, so ycashd and the probes' `ycash-cli` pick the same
  network), the ports (P2P 18833 / 18933 / 19033, RPC one below), the prefix magic
  (`f77962d3` / `d4` / `d5`; the prefix itself is shared), the kind NodePorts (31833 / 31933 /
  32033 and up, so all three fit one kind cluster) and the per-network secret. On the testnet
  cluster the seeds run on EC2 (`infra/testnet-seeds`, the same ports), so the deployment sets
  `seed.enabled=false` and `peers.addnode` to them; the verifier stays in the cluster.
  `testnetProfile` other than fast, slow, legacy or empty fails the render.
  - Images are the **release images by digest** (plan §6.1). The repositories are placeholders
    until T-12; the digests are set at deploy (`--set images.ycashd.digest=sha256:…`).
  - The chart refuses an image with neither tag nor digest. `make lint-testnet` and
    `scripts/lint-images.sh` render with a placeholder digest.

```bash
make lint-testnet     # helm lint + kubeconform: this chart (kind, EKS, every service on) and the lightwallet chart's testnet values
make services-test    # the faucet, the probe and status page, the state bundle: offline tests
scripts/lint-images.sh
helm template t charts/ycash-testnet -f charts/ycash-testnet/values-kind.yaml
```

Sizes (`storage.size` 50 Gi on EKS) are estimates until the full prefix harvest records its size
(N3-a).
