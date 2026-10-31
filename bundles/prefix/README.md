# The prefix harvests: Zcash-testnet history and Ycash-mainnet history

## In plain words

Ycash began in 2019 as a copy of Zcash, so the start of its history is Zcash's history. The new
Ycash testnet is built the same way: it starts from Zcash's public testnet, blocks 0 to 510,247,
and continues as Ycash from there. This directory holds the tool that copies those blocks out of
a Zcash node, checks each one, and packs them into files (the "prefix"). The checking means
nobody has to trust whoever made the files: anyone can rerun the tool and must get exactly the
same files, and anyone can re-check downloaded files with one command.

The same tool also copies **Ycash mainnet's** history, blocks 0 to a recent block H_S, with the
Ycash node itself. That copy is the history the shadow-fork testnets (testnet-yb-slow and
testnet-legacy) start from, and it is also the start of a mainnet bootstrap bundle. See
"Mainnet history" below.

The file layout is fixed in [FORMAT.md](FORMAT.md) (prefix format v1). The plan this serves is
`yellowback-testnet-plan.md` §2.1 and §4.0 in the workspace.

## What is here

| File | What it is |
|---|---|
| `FORMAT.md` | The frozen format contract: chunks, manifest, checksums, import framing |
| `harvest.py` | The whole tool, Python 3 standard library only: `export`, `pack`, `verify`, `tip`, `constants` |
| `Dockerfile` | The pack/verify image, on a base pinned by digest, so gzip produces the same bytes everywhere |
| `zebrad.toml` | The Zebra configuration: Testnet, JSON-RPC on loopback with cookie auth |
| `run-local.sh` | Runs everything with Docker: sync, export, verify, pack. CI runs this same script |
| `run-local-mainnet.sh` | The same for Ycash mainnet with ycashd (two nodes for the cross-check); the EC2 path |
| `publish-s3.sh` | Copies a verified bundle to an S3 location once, index files last |
| `data/ycash-main-checkpoints.txt` | Ycash's compiled mainnet checkpoints, vendored from a pinned ycash6 commit |
| `data/zebra-test-checkpoints.txt` | Zebra's testnet checkpoint list, vendored at a pinned commit |
| `tests/` | Offline unit tests on real Zcash testnet and Ycash mainnet blocks (`tests/vectors/SOURCE`) and a synthetic mainnet-shaped chain |

The pins live in one place, the top of `harvest.py`, and a unit test checks that the
`Dockerfile` and the workflow agree with them:

| Pin | Value |
|---|---|
| Zebra image | `docker.io/zfnd/zebra:7.0.0@sha256:a70d2be8ffef3a4b6e37355724e36a0e6c1838e46baa28bfb216739f00cf2d34` (git tag `v7.0.0` = `e8db87eb69254e0d4eedd058eadd48bdfa09065a`) |
| Zebra checkpoint list | `zebra-chain/src/parameters/checkpoint/test-checkpoints.txt` at `e8db87eb69254e0d4eedd058eadd48bdfa09065a`, sha256 `5d391844bbf7c67932125c9b0bdf0cef91b89460d13a3b8b6f7e3921cc9f5177` |
| Pack image base | `docker.io/library/python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5` |
| ycashd image (mainnet) | `ghcr.io/boyfromcave/ycashd:ycash6-71e74a9efc81@sha256:78f4a969c8bcffcf69a80da26c19a6b01c5932736f471a76fc3ee4c4c236c9b6` (node-image.yml, ycash6 `upgrade/vault` `71e74a9ef`) |
| Ycash mainnet checkpoint list | CMainParams `checkpointData`, `boyfromcave/ycash6` `src/chainparams.cpp` at `71e74a9efc8118ab72ad9b526e09b454f4e79b64`, sha256 `7ddc3bb48ec9ac6ff56e1bc5b18926584479d07a1faa128a5a35377b58a5c44f` |

**Why the checkpoint list is vendored, not fetched.** `verify` has to work offline, from the
downloaded files alone, so the list it checks against must be on disk. It is copied unchanged
from the pinned Zebra commit and `harvest.py` refuses to use it unless its sha256 matches the
pin. Anyone can confirm the copy is faithful:

```bash
curl -sS https://raw.githubusercontent.com/ZcashFoundation/zebra/e8db87eb69254e0d4eedd058eadd48bdfa09065a/zebra-chain/src/parameters/checkpoint/test-checkpoints.txt | sha256sum
# 5d391844bbf7c67932125c9b0bdf0cef91b89460d13a3b8b6f7e3921cc9f5177
```

Re-derive the mainnet list from the pinned ycash6 commit (CI's `mainnet-prefix` test job does this):

```bash
curl -sS https://raw.githubusercontent.com/boyfromcave/ycash6/71e74a9efc8118ab72ad9b526e09b454f4e79b64/src/chainparams.cpp \
  | python3 -I bundles/prefix/harvest.py main-checkpoints --chainparams - --check
# OK: 18 checkpoints (sha256 7ddc3bb4…c44f) and 3 activation hashes match
```

## Reproduce it on your own machine

You need Docker and bash, about 10 GB of disk for the full range, and an internet connection
that allows Zcash peer-to-peer traffic (TCP 18233).

```bash
bundles/prefix/run-local.sh 4799        # smoke range: blocks 0..4,799, minutes
bundles/prefix/run-local.sh             # the full prefix, 0..510,247: hours, mostly Zebra's sync
make prefix-local PREFIX_LAST=510247    # the same through make
```

The output lands in `prefix-work/out/` (`WORK=<dir>` moves it): the chunk files,
`manifest.json` and `SHA256SUMS`. `prefix-work/state/` keeps Zebra's state, so a rerun skips the
sync (it may hold a little more than the last height). It is owned by Zebra's user (uid 10001), so remove it with sudo or
`docker run --rm -v "$PWD/prefix-work:/w" busybox rm -rf /w/state`.

What the script does:
1. **Sync.** Starts `zebrad` from the pinned image on Testnet and lets it sync from peers. The
   script asks it for its height every 30 seconds until it is 10 blocks past the last height
   (`TIP_MARGIN`), so every block to copy has more blocks on top of it.
2. **Export.** While `zebrad` keeps running, fetches every block with `getblockhash` and
   `getblock <hash> 0` over JSON-RPC (cookie auth, on the container's loopback), then stops
   `zebrad` cleanly. Each block is checked as it arrives: the hash chain from the genesis and the
   checkpoints. Blocks this deep are below Zebra's own testnet checkpoints, so they cannot change.
   (Zebra is not restarted without the network for this: Zebra 7.0.0 starts its RPC server only
   after its peer-to-peer setup has resolved a DNS seeder, so with no network it never answers;
   the citations are in `run-local.sh`.)
3. **Pack.** In the pinned pack image, with no network: checks every block again, compresses each
   chunk with `gzip -n -9`, writes `manifest.json` and `SHA256SUMS`, then runs `verify` on the
   result.

## Audit it

Two independent checks, either is enough:

1. **Rerun and compare.** Run the workflow from a fork of this repository, or `run-local.sh` on
   your own machine, and compare your `SHA256SUMS` with the published one. Identical means the
   published files are exactly what Zcash testnet's history and this tool's commit produce.
2. **Re-verify the files you downloaded**, offline, with only Python 3:

   ```bash
   python3 -I bundles/prefix/harvest.py verify <dir-with-the-13-files>
   # or, with the pinned image:  docker run --rm --network none -v "$PWD/<dir>:/d:ro" ycash-prefix:local verify /d
   ```

   It checks `SHA256SUMS`, decompresses every chunk, re-derives every block hash, follows the hash
   chain from the genesis, matches all the anchors below, and recomputes `manifest.json` field by
   field.

For a published release, also check where the files came from:
`gh attestation verify <file> -R boyfromcave/ycash-infra` (GitHub build provenance, made by the
workflow's `publish` job).

### Check the owner's signature

In plain words: the signature proves the release owner published this exact checksum file; the
checksum file then vouches for every chunk.

```bash
minisign -Vm SHA256SUMS -P RWQYr5PFpiPJAigk86vf89bPYrJCXj5tskgRAPRYFsEXyciZo8dveOGQ    # SHA256SUMS.minisig beside it; or -p keys/ycash-release.pub
sha256sum -c SHA256SUMS
```

`keys/ycash-release.pub` (key id `02C923A6C593AF18`, `keys/README.md`) is the owner's minisign key
(T-6). The signature is added after the release is published, by the owner's signing workflow.

## The anchors

The prefix is pinned to Zcash testnet by things outside this repository:
- **The genesis block**, `05a60a92…2c38`, the same in Zebra, zcashd and Ycash.
- **Zebra's own source checkpoints**: 1,276 block hashes at or below 510,247, one every 400
  blocks, from the Zcash Foundation's repository at a pinned commit.
- **Ycash's compiled testnet pins**: the checkpoint at 38,000 and the Overwinter (207,500) and
  Sapling (280,000) activation hashes in `ycash6/src/chainparams.cpp`.
- **The hash chain and the Merkle roots**: every block points to the one before it, and every
  transaction is bound to its block's header, so matching the anchors fixes every byte between them.
- **The node itself**, when it imports the prefix: it validates every block, including the
  Equihash solutions this tool does not check.

## Tests

```bash
make prefix-test      # = python3 -I -m unittest discover -s bundles/prefix/tests -v
```

They run offline in seconds: header parsing and hashes on real Zcash testnet blocks (the genesis,
blocks 1..10, the Overwinter and Sapling activations, Sprout and Sapling transactions), a broken
hash chain, checkpoint mismatches, chunk boundaries (510,247 gives 11 chunks, the last
500,000..510,247; 4,799 gives one), packing the same stream twice giving identical bytes, and
an export from a stand-in Zebra RPC server with cookie auth and retries, and `run-local.sh` end to
end with a stand-in `docker` and a stand-in Zebra whose height climbs as it syncs
(`tests/test_run_local.py`, `tests/fake_docker.py`).

## CI

`.github/workflows/testnet-prefix.yml`: the tests and a smoke harvest (0..4,799) on every push and
pull request that touches this directory; the full range on a manual run (`last_height`), and the
release `testnet-prefix-v1` when that manual run sets `publish` (from `upgrade/vault`, full range
only, refused if the release exists). Each run's job summary lists `SHA256SUMS`, the file sizes
and how long each phase took.

## Mainnet history

### In plain words

testnet-yb-slow and testnet-legacy are "shadow forks" of the real Ycash network: they start from a
copy of Ycash mainnet's history up to a recent block (the split height, H_S) and continue from there
as testnets. This section is how that copy is made. A Ycash node syncs the real network from Ycash
peers; blocks 0..H_S are copied out, every block is checked against the checkpoints compiled into
Ycash and against the 2019 block where Ycash split from Zcash, and a second node, synced on its own,
confirms the blocks newer than the last compiled checkpoint. The files are made so that anyone who
reruns the job gets the same fingerprints. The same files are also the start of a mainnet bootstrap
bundle: a new mainnet node can load them instead of downloading every block from peers.

### How it runs

`run-local-mainnet.sh [H_S|auto]` does everything with Docker (its header lists every setting):

1. **Sync.** Starts ycashd (the pinned image) on mainnet with the network, RPC on the container's
   loopback with cookie auth, and (with `CROSSCHECK=sync`, the default) a second ycashd with its
   own datadir and, if `CROSSCHECK_CONNECT` names them, its own peers only. It waits until H_S is
   1,000 blocks deep: with `auto`, until the initial block download is complete, then H_S is the
   most recent height of the form k·10,000 − 1 at least 1,000 blocks below the tip (for example
   3,089,999), so every chunk holds exactly 10,000 blocks and the testnets' first own block is the
   round k·10,000. An explicit number is accepted as before.
2. **Export.** Restarts the main node with no network, so the chain cannot move, and copies blocks
   0..H_S with `getblockhash` / `getblock <hash> 0`, checking each one. Writes `z_gettreestate H_S`.
   Asks the second node for the cross-check hashes and its tree state, which must be identical.
3. **Pack.** In the pinned pack image with no network: verifies again, gzips the chunks (in
   parallel; the bytes do not depend on it), writes `manifest.json` (with `split`: H_S's hash,
   time and transaction count, and `crosscheck`), `treestate.json` and `SHA256SUMS`, and verifies
   the result from the files alone.

`CROSSCHECK=rpc` uses a node you already run elsewhere instead of a second sync
(`CROSSCHECK_RPC_URL`, `CROSSCHECK_RPC_USER`, `CROSSCHECK_RPC_PASSWORD`). `CROSSCHECK=none` is only
accepted for an H_S at or below 2,250,000.

### Where to run it: EC2 or a self-hosted runner

A GitHub-hosted job, larger runners included, stops after 6 hours, and a mainnet sync takes
longer, so the full harvest runs on a machine you control:

- **EC2, automated** (the expected path): `infra/mainnet-harvest` is a bucket plus a launch
  template for a one-shot instance that runs this script, uploads the bundle with `publish-s3.sh`,
  reads it back, reports its status into the bucket and terminates itself (a lifetime cap stops a
  stuck run). The operator's private workflow launches it and watches the bucket; see
  [its README](../../infra/mainnet-harvest/README.md), which starts "In plain words".
- **EC2, by hand**: an
  Ubuntu 22.04 or 24.04 instance with Docker, 4 to 8 vCPUs, 16 GB of memory or more, and a 500 GB
  gp3 volume; outbound TCP 8833 to Ycash peers. Then, in `tmux`:

  ```bash
  git clone https://github.com/boyfromcave/ycash-infra && cd ycash-infra
  WORK=/data/mainnet-work bundles/prefix/run-local-mainnet.sh auto      # resumable: rerun to continue
  python3 -I bundles/prefix/harvest.py verify /data/mainnet-work/out
  # publish to S3 with the instance's role (the bucket comes from you; nothing account-specific is here)
  bundles/prefix/publish-s3.sh /data/mainnet-work/out s3://<bucket>/<path>/mainnet-prefix-v1
  ```

  To publish the GitHub release from that machine, register it as a self-hosted runner and use
  the workflow below with `work_root=/data/mainnet-work`, or upload the files with
  `gh release create mainnet-prefix-v1 out/*`.
- **The workflow, on a self-hosted runner** (`.github/workflows/mainnet-prefix.yml`, dispatch):
  `runner` = the runner's label, `timeout_minutes` up to 7200, `work_root` = a directory kept
  between runs (the node datadirs survive, so a run cut short resumes), `split_height`,
  `crosscheck`, `crosscheck_connect`, `addnodes_url` (default the explorer's network page, below),
  `addnodes`, and `publish` with `publish_to` = `github`, `s3`
  or `github-and-s3`. The S3 target lives in the GitHub Environment `mainnet-prefix-s3`: secrets
  `PREFIX_S3_URI` (`s3://bucket/path`), `PREFIX_S3_REGION` and, for OIDC, `PREFIX_S3_ROLE_ARN`
  (without it the runner's own credentials are used, e.g. an EC2 instance profile).

On a push or a pull request the workflow only runs the offline tests. The harvest itself, which
connects to Ycash mainnet, runs only when started by hand (a trial: `split_height` 19999,
`crosscheck` none).

### Peers: read from the explorer at run time

**In plain words:** Ycash's built-in ways of finding peers no longer work: the DNS seed
`seed.ycash.xyz` returns no addresses and the two addresses compiled into Ycash 4.5.0 do not
answer (ycash6 has none). A fresh node therefore finds no one. The Ycash explorer publishes the
peers its own node sees, on `https://explorer.ycash.xyz/network.html` and as an `addnode=`
download, so the harvest reads that list when it runs (`fetch_addnodes.py`) and passes it to the
node. Nothing is hardcoded, and the addresses are not printed in the public log (only a count; the
node's peer log is shown with addresses masked if it finds no one). Locally: `python3 -I
bundles/prefix/fetch_addnodes.py --out peers.txt`, then `ADDNODES_FILE=peers.txt`.

### Sizes (estimates, to be replaced by the first run's numbers)

The owner's estimate for the mainnet datadir is 60 to 90 GB. The blocks themselves are a part of
that: Zcash's history up to the 2019 fork is the bulk, and Ycash's blocks since are mostly small.
Expect 309 chunk files for H_S = 3,089,999, each well under the 2 GiB limit, and gzip to
save little (proofs and ciphertexts do not compress). Disk at the peak: two node datadirs plus the
raw copy plus the packed copy (`KEEP_RAW=0`, the default, frees each raw chunk as it is packed), so
plan on 300 to 400 GB; with `CROSSCHECK=rpc` one datadir less.

### Import check

`.github/workflows/mainnet-prefix-import.yml` (dispatch) loads the bundle into both node lines'
current binaries under mainnet parameters (magic `24e92764`) with `import/import.sh --network
ycash-mainnet`, checks that each ends on H_S with the manifest's hash, checks every compiled and
cross-check height, and compares the node's `z_gettreestate` at H_S with `treestate.json`. A
`-checkpoints=0` leg is optional (`full`). The runner needs about three times the history's size.
