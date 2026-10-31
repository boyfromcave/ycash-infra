# `ghcr.io/boyfromcave/ycashd` — the Ycash node, as a container image

## In plain words

This is the Ycash full node (`ycashd`) packaged so that it runs anywhere Docker runs. It is built in
public, by a GitHub Actions workflow, from one exact commit of the node's source code, and every
image carries a signed record of that build (its *provenance*). Anyone can check that the image
they pulled came from that commit.

**What it is for today:** the three Ycash **practice networks (testnets)** that rehearse the
Ycash Yellowback (YED) vault upgrade with worthless coins. It is **not a release** of Ycash. The
images here are builds of the development line (`upgrade/vault`), made for the testnets' seed
machines and test clusters.

**Mainnet:** on mainnet this image behaves like an ordinary Ycash node. The vault upgrade and
Yellowback are **not active on mainnet** in any image published here: their mainnet activation
height and signer set are unset in the source, and only a future, separately announced Ycash
release can set them. Even so, for mainnet use the official Ycash releases, not these builds.

## The three testnets

| Testnet | What it rehearses | `YCASHD_TESTNET_PROFILE` | P2P port | RPC port |
|---|---|---|---|---|
| testnet-yb-fast | Yellowback with its waiting periods shortened, so a vault or a bond runs its course in hours | `fast` | 18833 | 18832 |
| testnet-yb-slow | Yellowback with every value as on mainnet; the activation itself is rehearsed live | `slow` | 18933 | 18932 |
| testnet-legacy | Today's Ycash rules with no upgrade: the control network | `legacy` | 19033 | 19032 |

All three share Zcash's testnet history up to block 510,247 and split at block 510,248, the
height at which Ycash itself forked from Zcash. Each has its own network ID, ports and data
directory, so they never mix.

## Run it

```bash
docker run -d --name ycashd-fast \
  -e YCASHD_NETWORK=testnet -e YCASHD_TESTNET_PROFILE=fast \
  -e YCASHD_RPC_USER=me -e YCASHD_RPC_PASSWORD="$(openssl rand -hex 16)" \
  -e YCASHD_RPC_BIND=127.0.0.1 \
  -e YCASHD_EXTRA_ARGS="-maxtipage=999999999" \
  -p 18833:18833 \
  -v ycash-fast:/var/lib/ycash \
  ghcr.io/boyfromcave/ycashd@sha256:<digest>
```

- **Pin by digest** (`@sha256:…`), as above. The tags (`ycash6-<commit>`, `ycash-dd-<commit>`) name
  the source commit and the node line, but only a digest is immutable.
- `YCASHD_NETWORK` is `mainnet` (the default), `testnet` or `regtest`. With `testnet`,
  `YCASHD_TESTNET_PROFILE` is required: the node refuses to start without knowing which testnet.
- **On a testnet, always pass `-maxtipage=999999999`** (as above; see "Keeping a quiet testnet
  alive" below). Never on mainnet.
- The chain data lives in `/var/lib/ycash`; mount a volume there.
- **Peers:** the testnets have no DNS seed; their seed nodes' fixed addresses are compiled into
  each testnet release candidate. Until then, add peers with `-e YCASHD_EXTRA_ARGS="-addnode=<host>:<port>"`.
- **Zcash parameters:** the `ycash6-…` images carry the Sapling proving parameters built in; nothing
  to download. The `ycash-dd-…` images (the 4.5.0 line) read them from `~/.zcash-params`. They are
  mirrored, with their checksums, at the
  [`zcash-params-v1`](https://github.com/boyfromcave/ycash-infra/releases/tag/zcash-params-v1)
  release.
- Every setting the entrypoint reads (RPC, listening, the address index, extra `ycash.conf` lines):
  `contrib/docker/ycashd/README.md` in the node's source repository, at the image's commit.

## Keeping a quiet testnet alive: `-maxtipage`

**In plain words:** a testnet has few miners, and its difficulty can be high for the hardware
pointed at it, so it may go hours or days without a block. That is fine: the chain does not die,
and anyone can resume mining later. But a node judges whether it is "still catching up" by the age
of the newest block. If that block is more than a day old (`-maxtipage`, default 86,400 seconds),
a node that has just started believes it is still syncing, and then:

- it refuses `getblocktemplate` ("Ycash is downloading blocks..."), so a miner cannot restart the chain;
- it ignores other nodes' requests for block headers, so newcomers cannot sync from it.

`-maxtipage=999999999` (about 31 years) switches that judgement off. It changes no consensus rule:
the blocks a node accepts are the same with or without it. Every node we run on the testnets sets it
(the seeds, `charts/ycash-testnet`, the lightwallet chart's testnet values); set it on yours too,
above all on the node a miner or pool (yolo) talks to. On mainnet leave the default.

The flag does not lower the difficulty. Each testnet also has the standard testnet rule: when no
block has come for six block intervals, the next block may be mined at the network's minimum
difficulty. On testnet-yb-slow and testnet-legacy that minimum is mainnet's, so they need a GPU
miner (through yolo) even then.

## Check what you pulled

```bash
gh attestation verify oci://ghcr.io/boyfromcave/ycashd@sha256:<digest> -R boyfromcave/ycash-infra
docker inspect ghcr.io/boyfromcave/ycashd@sha256:<digest> \
  --format '{{index .Config.Labels "org.ycash.node.repository"}} {{index .Config.Labels "org.ycash.node.revision"}}'
```

The first command checks the build provenance: built by this repository's `node-image` workflow.
The second prints the node source repository and the exact commit the image was built from.

## How it is built

- **Workflow:** [`.github/workflows/node-image.yml`](../../.github/workflows/node-image.yml), started
  by hand from `upgrade/vault`.
- **Source:** it takes a node line (`ycash6` or `ycash-dd`) and a full commit ID, refuses a commit
  that is not on that repository's `upgrade/vault`, and builds that tree's own
  `contrib/docker/ycashd/Dockerfile`. No node source is kept in this repository.
- **Platform and time:** linux/amd64 only. The build compiles every dependency from source, so it
  takes one to two hours.

## License

MIT, as the Ycash source it is built from (`COPYING` in the node's source repository).
