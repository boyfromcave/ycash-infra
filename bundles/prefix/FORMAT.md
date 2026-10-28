# Zcash-testnet prefix, format v1 (`ycash-prefix/1`)

## In plain words

The new Ycash testnet starts from a copy of Zcash's public testnet history, block 0 through
block 510,247, the block before Ycash splits off. This page says exactly how that copy is laid
out in files, so that two programs written by different people (the one that makes the files
and the one that loads them into a Ycash node) agree on every byte. The blocks are cut into
eleven compressed files of up to 50,000 blocks each, plus a `manifest.json` that describes them
and a `SHA256SUMS` file of fingerprints. Anyone can make the files again and must get the same
fingerprints; that is how the copy is audited.

This contract is **frozen**. A change to anything below is a new format version (`ycash-prefix/2`,
new file names, a new release tag), never an edit of v1.

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

## Notes on this implementation (not part of the contract)

These record how `harvest.py` fills in the contract; a second implementation is free to differ
here and must still produce the same bytes.

- Line citations are at `ycash6` `upgrade/vault` `1c10c93cc`.
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
