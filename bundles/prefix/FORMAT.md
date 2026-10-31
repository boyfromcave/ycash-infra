# Prefix format v1 (`ycash-prefix/1`): Zcash-testnet and Ycash-mainnet history

## In plain words

The new Ycash testnet starts from a copy of Zcash's public testnet history, block 0 through
block 510,247, the block before Ycash splits off. This page says exactly how that copy is laid
out in files, so that two programs written by different people (the one that makes the files
and the one that loads them into a Ycash node) agree on every byte. The blocks are cut into
eleven compressed files of up to 50,000 blocks each, plus a `manifest.json` that describes them
and a `SHA256SUMS` file of fingerprints. Anyone can make the files again and must get the same
fingerprints; that is how the copy is audited.

The same format also carries a second history: **Ycash mainnet**, blocks 0 to a recent block H_S
(network `ycash-mainnet`, section "Network ycash-mainnet" below). That copy is the history the
shadow-fork testnets (testnet-yb-slow and testnet-legacy) start from, and it is also the start of
a mainnet bootstrap bundle: a new mainnet node can load it instead of downloading every block from
peers. Only a few things differ between the two networks (chunk size, file names, genesis, the
checkpoints checked, and three extra mainnet facts); everything else below is shared.

This contract is **frozen**. A change to anything below is a new format version (`ycash-prefix/2`,
new file names, a new release tag), never an edit of v1. Adding the `ycash-mainnet` network
(2026-10-31) changed nothing for `zcash-testnet`: its files, manifest and checks are byte for byte
what they were.

## Contract

**Network and range.** Zcash testnet, heights **0..510,247 inclusive** (510,248 blocks). The
Ycash testnet fork is at 510,248 (`ycash6/src/chainparams.cpp:433-436`). Smoke mode uses a
smaller last height (default 4,799) with the same chunking rule; everything below then applies
with that last height in place of 510,247.

**Chunks.** Chunk k (k = 0..10) covers heights [50,000·k, min(50,000·k + 49,999, 510,247)].
So chunks 0..9 hold 50,000 blocks each and chunk 10 holds 500,000..510,247 (10,248 blocks).

**Chunk payload ("raw block stream").** For each block in height order: a 4-byte little-endian
unsigned length L, then the L bytes of the canonical serialized block (exactly what Zebra's
`getblock <hash> 0` returns, hex-decoded). No network magic (magic-neutral).

**Chunk file.** `zcash-testnet-prefix-v1-<first:07d>-<last:07d>.blocks.gz`, produced by
`gzip -n -9` of the raw stream, inside a pinned container image (so the bytes are reproducible).
For example `zcash-testnet-prefix-v1-0000000-0049999.blocks.gz` and
`zcash-testnet-prefix-v1-0500000-0510247.blocks.gz`; the smoke range is the single file
`zcash-testnet-prefix-v1-0000000-0004799.blocks.gz`.

**Block hash.** SHA-256d of the serialized header *including* the Equihash solution
(version..nonce = 140 bytes, then compactsize + solution), displayed byte-reversed hex, as in
zcashd.

**Verification.** Every harvest checks, and every consumer may re-check:
- the hash chain: each block's `hashPrevBlock` equals the previous block's hash;
- the genesis: `05a60a92d99d85997cce3b87616c089f6124d7342af37106edc76126334a2c38`;
- every height in Zebra's `zebra-chain/src/parameters/checkpoint/test-checkpoints.txt` (at the
  pinned Zebra commit, `sources.zebra_checkpoints_commit`) that is ≤ the last height;
- Ycash's compiled testnet checkpoints and activation hashes ≤ the last height:
  - 38000 `001e9a2d2e2892b88e9998cf7b079b41d59dd085423a921fe8386cecc42287b8`
  - 207500 `0000257c4331b098045023fcfbfa2474681f4564ab483f84e4e1ad078e4acf44`
  - 280000 `000420e7fcc3a49d729479fb0b560dd7b8617b178a08e9e389620a9d1dd6361a`

**`manifest.json`.** Canonical: UTF-8, sorted keys, 2-space indent, a trailing newline, and no
timestamps or runner-dependent values. Fields:
- `format`: `"ycash-prefix/1"`
- `network`: `"zcash-testnet"`
- `first_height`, `last_height`
- `chunks`: `[{file, first_height, last_height, blocks, raw_bytes, raw_sha256, gz_bytes, gz_sha256}]`
- `hashes`: `{"<height>": "<hash>"}` for every multiple of 10,000 ≤ the last height, plus the last height
- `sources`: `{zebra_image: "<image@sha256:…>", zebra_checkpoints_commit: "<sha>", pack_image: "<image@sha256:…>"}`

**`SHA256SUMS`.** `sha256sum` format (`<hex>  <name>`) over every `.blocks.gz` and
`manifest.json`, sorted by name.

**Import framing** (the import side). For each block, write
`<4-byte network magic><4-byte LE length><block>` into a file the node reads with
`-loadblock=<file>`. The current testnet magic on both node lines is `fa 1a f9 bf`
(`ycash6/src/chainparams.cpp:539-542`); the importer takes the magic as a parameter, so the
prefix does not change when the testnet's magic does.

## Network ycash-mainnet

### In plain words

This is Ycash's real history, copied the same way: blocks 0 through H_S, the split height chosen
when the copy is made. Ycash mainnet has far more history than the old Zcash testnet (tens of
gigabytes), so its files are cut smaller (10,000 blocks each, so no file comes near GitHub's
2 GiB limit per download). The copy is checked against every checkpoint compiled into the Ycash
node and against the block where Ycash split from Zcash in 2019. The newest compiled checkpoint is
block 2,250,000; for the blocks after it a second, independently synced node must agree, and its
answers are written into the manifest. The manifest also records the facts a testnet built on H_S
needs (the block's time and how many transactions the chain holds up to it), and the node's
shielded tree state at H_S is published beside the blocks for wallets.

### Contract

Everything in "Contract" above applies, with `zcash-testnet` read as `ycash-mainnet` and these
differences:

- **Range.** Heights **0..H_S inclusive**. H_S, the split height, is the last copied block and the
  manifest's `last_height`. It is chosen when the harvest runs: by default the most recent multiple
  of 10,000 that is at least 1,000 blocks below the synced tip. Any H_S ≥ 0 is valid; one above
  2,250,000 needs the cross-check below.
- **Chunks.** Chunk k covers heights [10,000·k, min(10,000·k + 9,999, H_S)]. An H_S on a multiple
  of 10,000 makes the last chunk a single block. Every chunk file must be under 2 GiB
  (2,147,483,647 bytes); the packer refuses a bigger one.
- **Chunk file.** `ycash-mainnet-prefix-v1-<first:07d>-<last:07d>.blocks.gz`, the same payload and
  `gzip -n -9` as above.
- **Block layout.** As above, except the Equihash solution: 1,344 bytes (Equihash 200, 9) below
  570,000 and **400 bytes (Equihash 192, 7) from the Ycash fork at 570,000** on.
- **Verification.** The hash chain from the genesis
  `00040fe8ec8471911baa1db1266ea15dd06b4a8a5c453883c000b031973dce08`; every Ycash compiled mainnet
  checkpoint ≤ H_S (CMainParams `checkpointData` in `boyfromcave/ycash6` `src/chainparams.cpp` at the
  pinned commit `sources.ycash_checkpoints_commit`, vendored as `data/ycash-main-checkpoints.txt`,
  18 entries 0..2,250,000, the same on ycash-dd); and the compiled activation hashes ≤ H_S:
  - 347500 `0000000003761c0d0c3974b54bdb425613bbb1eaadd6e70b764de82f195ea243` (Overwinter)
  - 419200 `00000000025a57200d898ac7f21e26bf29028bbe96ec46e05b2c17cc9db9e4f3` (Sapling)
  - 570000 `0000014fbc5917ba8bcacf3336faf588d86b32443aa3a490a587af5750c77ec5` (the Ycash fork block,
    `UPGRADE_YCASH.hashActivationBlock`)
- **Cross-check.** Blocks above the newest compiled checkpoint (2,250,000) are trusted only to the
  node that served them. So a second node, synced independently (its own datadir, ideally its own
  peers), is asked for the block hash at every multiple of 100,000 strictly between 2,250,000 and
  H_S, and at H_S. Every answer must equal the harvested chain's hash at that height.
- **`treestate.json`.** The exporting node's `z_gettreestate "<H_S>"` answer, as canonical JSON
  (sorted keys, 2-space indent, trailing newline). Its `height`, `hash` and `time` must be H_S's;
  the cross-check node's answer must be identical. Its tree states are not derivable from the block
  headers (Heartwood replaced the Sapling root in the header with the chain history root at
  1,100,003), so the importer compares them with what the node computes.
- **`manifest.json`.** The fields above, with `network: "ycash-mainnet"`, `sources:
  {ycashd_image: "<image@sha256:…>", ycash_checkpoints_commit: "<sha>", pack_image: "<image@sha256:…>"}`,
  and three more:
  - `split`: `{height, hash, time, chaintx}`: H_S, its hash, its header `nTime`, and the number of
    transactions in blocks 0..H_S (what a chain profile's `checkpointData` needs);
  - `crosscheck`: `{"<height>": "<hash>"}` for exactly the cross-check heights (empty when H_S ≤ 2,250,000);
  - `treestate`: `{file: "treestate.json", sha256: "<hex>"}`.
- **`SHA256SUMS`.** Over every `.blocks.gz`, `manifest.json` and `treestate.json`, sorted by name.
- **Import framing.** As above with the mainnet magic `24 e9 27 64` (ycash6 `src/chainparams.cpp:223-226`),
  under mainnet parameters (no `-testnet`).
- **Release.** `mainnet-prefix-v1` (a GitHub release of this repository, or an S3 location under that
  name), immutable once published.

## Notes on this implementation (not part of the contract)

These record how `harvest.py` fills in the contract; a second implementation is free to differ
here and must still produce the same bytes.

- Line citations are at `ycash6` `upgrade/vault` `1c10c93cc` (testnet) and `71e74a9ef` (mainnet).
- ycash-mainnet: `sources.ycashd_image` is the node image the export used, pinned in `harvest.py`.
  Any honest ycashd returns the same block bytes; pinning it keeps the manifest, and so SHA256SUMS,
  identical across reruns. What ran where (tips, peers, timings) is written to
  `harvest-report.json` beside the work directory, never into the bundle.
- ycash-mainnet chunk size: 10,000 blocks. A chunk reaches 2 GiB only at an average block of about
  215 KB over 10,000 consecutive blocks; Zcash's history before 570,000 and Ycash's after it are far
  below that. The packer checks the limit anyway.
- `sources.pack_image` names the pinned **base** image of `Dockerfile` (it supplies gzip and
  Python). The image built from it adds only this directory's `harvest.py` and `data/`, so it is
  a function of the base digest and the repository commit.
- Byte counts: `raw_bytes` is the size of the uncompressed raw stream (length prefixes included);
  `blocks` is the number of blocks in the chunk; `gz_bytes` the size of the `.blocks.gz` file.
- Beyond the contract's checks, `harvest.py` also checks for each block: the 1,344-byte Equihash
  (200, 9) solution length, the hash against the nBits target, every transaction parsed to the
  block's last byte (v1..v4), and the Merkle root. So every byte of a chunk is bound to the hash
  chain. The Equihash solution itself is checked by the node on import.
- Ycash's 38,000 and 280,000 pins are also in Zebra's list and agree with it; 207,500 is not a
  multiple of 400, so only Ycash pins it. Zebra's list has 1,276 heights ≤ 510,247.
- The plan (`yellowback-testnet-plan.md` §2.1, §4.0) describes the chunks as `tar` + `gzip`
  archives; the frozen contract above (a gzip of the raw stream, no tar) supersedes that.
