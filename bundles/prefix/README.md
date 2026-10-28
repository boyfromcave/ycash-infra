# The Zcash-testnet prefix harvest

## In plain words

Ycash began in 2019 as a copy of Zcash, so the start of its history is Zcash's history. The new
Ycash testnet is built the same way: it starts from Zcash's public testnet, blocks 0 to 510,247,
and continues as Ycash from there. This directory holds the tool that copies those blocks out of
a Zcash node, checks each one, and packs them into files (the "prefix"). The checking means
nobody has to trust whoever made the files: anyone can rerun the tool and must get exactly the
same files, and anyone can re-check downloaded files with one command.

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
| `data/zebra-test-checkpoints.txt` | Zebra's testnet checkpoint list, vendored at a pinned commit |
| `tests/` | Offline unit tests on real Zcash testnet blocks (`tests/vectors/SOURCE`) |

The pins live in one place, the top of `harvest.py`, and a unit test checks that the
`Dockerfile` and the workflow agree with them:

| Pin | Value |
|---|---|
| Zebra image | `docker.io/zfnd/zebra:7.0.0@sha256:a70d2be8ffef3a4b6e37355724e36a0e6c1838e46baa28bfb216739f00cf2d34` (git tag `v7.0.0` = `e8db87eb69254e0d4eedd058eadd48bdfa09065a`) |
| Zebra checkpoint list | `zebra-chain/src/parameters/checkpoint/test-checkpoints.txt` at `e8db87eb69254e0d4eedd058eadd48bdfa09065a`, sha256 `5d391844bbf7c67932125c9b0bdf0cef91b89460d13a3b8b6f7e3921cc9f5177` |
| Pack image base | `docker.io/library/python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5` |

**Why the checkpoint list is vendored, not fetched.** `verify` has to work offline, from the
downloaded files alone, so the list it checks against must be on disk. It is copied unchanged
from the pinned Zebra commit and `harvest.py` refuses to use it unless its sha256 matches the
pin. Anyone can confirm the copy is faithful:

```bash
curl -sS https://raw.githubusercontent.com/ZcashFoundation/zebra/e8db87eb69254e0d4eedd058eadd48bdfa09065a/zebra-chain/src/parameters/checkpoint/test-checkpoints.txt | sha256sum
# 5d391844bbf7c67932125c9b0bdf0cef91b89460d13a3b8b6f7e3921cc9f5177
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
