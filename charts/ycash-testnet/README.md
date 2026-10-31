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
three since the testnet profiles merged (N1). The chart is checked and rendered in CI but has not
yet run on a cluster. It holds no keys of any kind.

Plan: workspace `docs/plans/yellowback-testnet-plan.md` (§2.3 who runs what, §4.0 the prefix,
§6 this environment); this repository's `docs/plans/ycash-infra-plan.md` K5–K7.

## What it runs

| Role | Kind | Image | Notes |
|---|---|---|---|
| `seed` | StatefulSet, 3 replicas | `ycash6` (`images.ycashd`) | `podAntiAffinity` by zone (required on EKS, preferred by hostname on kind); a PVC per pod; P2P 18833 through **one Service per pod** (`seed.p2pService`: an internet-facing NLB per seed on EKS, NodePort 31833–31835 on kind), not-ready pods still published |
| `verifier-dd` | StatefulSet, 1 replica | `ycash-dd` (`images.ycashdLegacy`) | The cross-line verifier: syncs from the seeds over P2P. Its Sprout/Sapling parameter files on their own PVC (`verifierDd.zcashParams`), filled by the `zcash-params` init container (below) |
| `prefix-fetch`, `prefix-frame` | init containers on both, **off by default** | the node image; the future framer image | below |

Both roles render from one template (`templates/node.yaml`); everything that differs is a value
(AGENTS.md rule 2). Each pod:
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
checkpoints skip (plan §4.0). The state bundle and `ycash-bootstrap` (plan §4.1, §4.4) come later
(N2).

## What it deliberately leaves out

| Not here | Why | Waits for |
|---|---|---|
| `miner` (`-gen -mineraddress`), `pool` (yolo) | needs a payout key | T-9 (the `AGENTS.md` rule 4 amendment for this chart), N1 |
| `attestor` (house seats), `bridge-persona` | hold signing keys | T-9, T-5 (the founding set), N1 |
| `faucet` | spends a wallet | T-9 |
| `dnsseed` | needs the new magic and a delegated hostname | N1 (T-2), T-3 |
| `snapshotter`, `bundle-verifier` | need `-stopatheight` (node change) and the signing setup | N1, T-6 |
| `status` page, alerts (plan §6.4) | nothing to watch yet | N3 after N1 |

Nothing in this chart holds a seed, a spending key or a payout address; `rpcuser`/`rpcpassword` are
the only secrets and they are the nodes' own (`AGENTS.md` rule 4, unchanged).

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
make lint-testnet     # helm lint + kubeconform: this chart (kind, EKS) and the lightwallet chart's values-testnet.yaml
scripts/lint-images.sh
helm template t charts/ycash-testnet -f charts/ycash-testnet/values-kind.yaml
```

Sizes (`storage.size` 50 Gi on EKS) are estimates until the full prefix harvest records its size
(N3-a).
