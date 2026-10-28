# Prefix import checks

## In plain words

The new Ycash testnet starts from a copy of Zcash's public testnet history, blocks 0 to 510,247
(the "prefix", made by the `testnet-prefix` job, `../FORMAT.md`). Before anyone builds on that
copy, we need to know that the Ycash node software accepts it. This directory holds the check:
it hands the copy to a real Ycash node as if it were a block file on its disk, waits until the
node has checked and stored every block, and then compares the node's chain with the fingerprints
listed in the copy. It runs for both versions of the node (`ycash6` and `ycash-dd`), once with the
node's usual shortcuts and once checking everything from scratch, and writes down the result:
whether it passed, the final block, a fingerprint of all coins at that point, how long it took and
how much disk it used.

Nothing in the copy is ever run as a program. It is only read and checked.

## Files

| File | What it does |
|---|---|
| `frame.py` | Checks the prefix as data (`SHA256SUMS`, `manifest.json`, every chunk, every block) and writes one `-loadblock` file per chunk, each block framed `<magic> <LE u32 length> <block>` |
| `import.sh` | Verifies and frames the prefix, starts `ycashd -testnet` on a fresh datadir with the framed files, waits for the tip, checks the hashes, records the node's state, stops the node, writes a result JSON |
| `summarize.py` | Prints results as a Markdown table and fails when a result failed or two results disagree |
| `tests/test_frame.py` | Unit tests of `frame.py` on real Zcash testnet blocks 0..10 (round trip, the node's record scan, every refusal) |
| `tests/test_import.sh` | `import.sh` and `summarize.py` against a stand-in node (`tests/mocknode/`): clean imports in both modes, a refused block, a corrupted chunk, a non-empty work directory |
| `tests/make_prefix.py` | Builds a small format-v1 prefix from hex blocks (tests only; the real prefix comes from the harvest) |
| `../../../.github/workflows/testnet-prefix-import.yml` | The CI: {ycash6, ycash-dd} × {checkpoints, full} after each successful `testnet-prefix` run, or on dispatch |

All Python is standard library only and runs under `python3 -I`.

## Usage

```bash
# unit tests (seconds)
python3 -I bundles/prefix/import/tests/test_frame.py
bundles/prefix/import/tests/test_import.sh

# frame only (checks the prefix, writes blk-*.dat)
python3 -I bundles/prefix/import/frame.py --prefix PREFIX_DIR --out FRAMED_DIR [--magic fa1af9bf] \
  [--expect HEIGHT:HASH ...] [--summary summary.json]

# a real import
bundles/prefix/import/import.sh --bin DIR_WITH_YCASHD_AND_CLI --prefix PREFIX_DIR \
  --mode checkpoints|full --work EMPTY_DIR --out result.json --line ycash6 --node-sha SHA \
  [--paramsdir ~/.zcash-params]   # ycash-dd only
```

`import.sh --help` lists every option (stall timeout, overall timeout, `-dbcache`, `--keep`).
Exit status 0 means every check passed; 1 means a check failed and the result JSON says which; 2 is
a usage error. Node flags: `-testnet -connect=0 -listen=0 -dnsseed=0 -discover=0 -disablewallet=1
-dbcache=2048 -loadblock=…` (one per chunk, in height order), plus `-checkpoints=0` in `full`
mode and `-paramsdir` when given. RPC credentials are random per run, bound to 127.0.0.1.

### What is checked

Before the node starts (`frame.py`; any failure removes the partial output):
- `SHA256SUMS` names exactly `manifest.json` and the manifest's chunks, sorted, and every sum matches;
- the manifest: `ycash-prefix/1`, `zcash-testnet`, chunks cut by the v1 rule (50,000 blocks),
  `gz_bytes`/`gz_sha256` agree with the files and with `SHA256SUMS`, a hash at every 10,000th height
  and at the last height;
- each chunk while streaming: `raw_bytes`, `raw_sha256`, the block count, every block's length
  within 80..2,000,000 (what the node would otherwise skip silently), the hash chain, the genesis hash,
  every manifest hash and Ycash's compiled hashes at 38,000, 207,500 and 280,000 (when the prefix
  reaches them).

After the import (`import.sh`): the tip equals the manifest's last height and hash; `getblockhash`
at every manifest height and at the three compiled heights; then `getblockchaininfo` and
`gettxoutsetinfo` are recorded, the node is stopped with `ycash-cli stop` and must exit 0.

### The result JSON

`ok`, `failure`, `line`, `node_sha`, `mode`, `node_version`, `node_args`, `node_exit`, `prefix`
(manifest sha256, last height, tip, chunks, raw bytes, magic, the harvest's `sources`),
`hash_checks` (`checked`, `mismatches`), `seconds` (`frame`, `import`, `total`), `datadir_bytes`,
`getblockchaininfo`, `gettxoutsetinfo`, `utxo` (`height`, `bestblock`, `transactions`, `txouts`,
`hash_serialized`, `total_amount`), the progress log and, on failure, the last 200 lines of
`debug.log`. `summarize.py` compares results: one tip across all of them, and within one line the
same `hash_serialized` and `total_amount` for both modes (the two lines' serialisations are not
compared with each other).

## Node behaviour this relies on

Cited at ycash6 `1c10c93cc73e89783edcdf690eece90b211077e1` and ycash-dd
`1bbcf26bc9df6daed171dacf0e79a37358915ddd` (both `upgrade/vault`, 2026-10-28).

**How `-loadblock` imports.** `ThreadImport` reads each `-loadblock` file in the order given
(ycash6 `src/init.cpp:849`, `:904-912`; ycash-dd `src/init.cpp:722`, `:777-786`) through
`LoadExternalBlockFile` (ycash6 `src/main.cpp:7673`; ycash-dd `src/main.cpp:5782`). That function
scans for the first byte of the network magic, compares all four bytes, reads a little-endian
`u32` length and skips any record whose length is below 80 or above `MAX_BLOCK_SIZE` (ycash6
`:7698-7706`; ycash-dd `:5807-5815`). After a block it resumes right after that block, so magic
bytes inside block data never cause a misread. A block whose parent is unknown is dropped when
importing from a file (ycash6 `:7724-7730`; ycash-dd `:5833-5839`): the files must be in height
order, which the v1 chunks are. Each block goes through `ProcessNewBlock`, so the tip advances
during the import and `getblockcount` shows progress: ycash-dd always (`:5844`), ycash6 with its
default one-phase mode (`:7740`, `DEFAULT_REINDEX_ONE_PHASE = true` in `src/main.h:163`). ycash6
then calls `ActivateBestChain` once more (`src/init.cpp:917`). Each file ends with the log line
`Loaded N blocks from external file` (ycash6 `:7800`; ycash-dd `:5882`); `import.sh` uses it to
tell a refused block (every file read, tip short) from a slow one.

**The magic.** Testnet magic `fa 1a f9 bf` on both lines (ycash6 `src/chainparams.cpp:539-542`;
ycash-dd `:480-483`). Genesis is Zcash testnet's `05a60a92…2c38` on both (ycash6 `:552`;
ycash-dd `:494`).

**`-connect=0`** disables outbound connections on both lines (ycash6 `src/net.cpp:1974`;
ycash-dd `src/net.cpp:1978`).

**Checkpoints: what `checkpoints` mode skips, and that the two lines differ.** Both lines carry the
old testnet checkpoints 0, 38,000 and 650,000 (ycash6 `src/chainparams.cpp:568-577`; ycash-dd
`:509-518`). 650,000 is above the prefix and belongs to the lost old Ycash branch.
- ycash6 skips the expensive checks (proofs and scripts) for every block at or below the *height*
  of the last checkpoint, 650,000 (`src/main.cpp:3538-3540`, `src/checkpoints.cpp:88-94`). It also
  enforces the hash at each checkpoint height while accepting the header (`src/main.cpp:6150-6165`),
  so block 38,000 must match.
- ycash-dd skips them for every block that `IsAncestorOfLastCheckpoint` accepts
  (`src/main.cpp:3121-3124`). While importing (`fImporting`), that is every block at or below
  650,000 (`src/checkpoints.cpp:81-100`, the import workaround). ycash-dd does **not** check
  checkpoint hashes when accepting headers; it only refuses forks below the last checkpoint it
  already holds (`src/main.cpp:4752-4758`). During a `-loadblock` import of this prefix, ycash-dd
  therefore never compares block 38,000 with its checkpoint. `import.sh` checks that hash (and
  207,500 and 280,000) itself, in the prefix before the import and in the node after it.
- So in `checkpoints` mode **neither line verifies a proof or a script anywhere in the prefix**.
  It verifies Equihash, proof of work and difficulty, structure, merkle roots, contextual and
  consensus value rules (founders' reward, the value pools). `full` mode (`-checkpoints=0`) turns
  the expensive checks on for every block (`fCheckpointsEnabled`, ycash6 `src/init.cpp:1291`;
  ycash-dd `src/init.cpp:1154`).

**Sprout proofs.** Neither line verifies a BCTV14 (PHGR13) Sprout proof, even with
`-checkpoints=0`: `SproutProofVerifier` returns true for them ("We checkpoint after Sapling
activation", ycash6 `src/proof_verifier.cpp:26-31`; ycash-dd `src/proof_verifier.cpp:26-31`). Every
JoinSplit before Sapling (280,000) uses BCTV14, so those proofs are taken on trust in both modes.
Groth16 Sprout proofs (from Sapling on) and Sapling proofs are verified in `full` mode.

**zk parameters.**
- ycash6 needs no parameter files. The Sprout Groth16 verifying key is compiled in
  (`src/rust/src/init.rs:42`), the Sapling parameters are bundled (`init.rs:48-57`), and
  `ZC_LoadParams` only logs where it would fetch the Sprout proving parameters
  (`src/init.cpp:947-975`). This matches `doc/yellowback-release.md:25-26`.
- ycash-dd needs `sapling-spend.params`, `sapling-output.params` and `sprout-groth16.params` in
  `-paramsdir` (default `~/.zcash-params`, `src/util.cpp:259-285`). Without them it shuts down at
  startup (`src/init.cpp:819-836`). The workflow fetches them from `download.z.cash` and checks the
  sha256 sums that ycash-dd's `zcutil/fetch-params.sh:223-225` pins.

**Initial block download and `nMinimumChainWork`.** While importing, both lines report initial block
download (`fImporting`, ycash6 `src/main.cpp:2563`; ycash-dd `src/main.cpp:2340`). Afterwards they
stay in IBD while the tip's chain work is below `nMinimumChainWork`: ycash6 testnet
`0x263c0984a2` (`src/chainparams.cpp:537`), ycash-dd `0x1959b78e6f` (`:478`). Both values come from
the old Ycash branch beyond the fork. If the prefix's chain work at 510,247 were at or above one
of them, that line's `IsInitialBlockDownload` would reach the activation-hash check (ycash6
`:2581`; ycash-dd `:2358`), find `UPGRADE_YCASH` (hash pinned, height 510,248) not yet active and
call `AbortNode`. `import.sh` would report that as "ycashd exited during the import". Zcash testnet's
work at 510,247 is expected to be well below both values; the result records `chainwork` in
`getblockchaininfo`, so the first run measures it. N1's re-fork replaces these values (testnet plan §2.1).

## Test data

`tests/data/zcash-testnet-blocks-0-10.hex`: Zcash testnet blocks 0..10, one hex block per line,
from Zebra's test vectors `zebra-test/src/vectors/block-test-0-000-000.txt` .. `-010.txt` at
ZcashFoundation/zebra commit `7fc69a39eb1fcf0e8abab3d158c295b503f05c11` (main on 2026-10-28). Block
0 hashes to the testnet genesis `05a60a92…2c38`, and each block's `hashPrevBlock` links to the one
before (`test_frame.py` asserts both).

## What is not verified here

- No real `ycashd` ran locally: the sandbox cannot fetch GitHub Actions artifacts (the artifact
  blob host is denied), and the workspace rules forbid building the node here. `import.sh` is
  tested against the stand-in node only. The first CI run is the first real import.
- Timing and disk for the full prefix are not measured yet. `-checkpoints=0` must verify every
  Sapling and Groth16 Sprout proof and every script up to 510,247 on a 4-core hosted runner; the
  `full` legs get 355 minutes, close to the 6-hour limit of a hosted job. If they do not fit, they
  need a larger or self-hosted runner, as the plan foresees for the harvest.
- The `node-bin` artifacts of the node repositories are kept 3 days. Importing an older commit
  means dispatching that repository's `yellowback-tests.yml` on it first.
