# Testnet state bundle, format v1 (`ycash-state/1`)

## In plain words

A new node normally spends hours downloading and checking the whole chain before it is useful. A
**state bundle** is a packed copy of a node's working files, taken at an agreed block, so that a new
node can start in minutes instead. Because nobody should have to trust whoever made the copy, every
bundle comes with short **statements**: two different node programs (the current Ycash node and the
older Ycash line) each sync the chain on their own, stop at the same block, and write down
fingerprints of everything they hold there. The bundle is published only when those statements are
identical, and a node started from the bundle can check the same fingerprints itself. This page says
exactly how a bundle is laid out, so that the program that makes bundles (the snapshotter in
`charts/ycash-testnet`) and the programs that use them (`ycash-bootstrap`, `verify.py` here) agree on
every byte. It parallels the history bundle's page, [`../prefix/FORMAT.md`](../prefix/FORMAT.md).

A change to anything under "Contract" is a new format version (`ycash-state/2`), never an edit of v1.

## Where it sits

Workspace testnet plan §4.0 (two layers: an immutable prefix, a rolling state bundle), §4.1 (this
bundle), §4.2 (why it can be trusted), §4.3 (how it is produced). The prefix bundle holds blocks only
and never changes; a state bundle holds a whole ycash6 datadir at a height `H_B` above the fork and is
made again for each release candidate (and by the daily CronJob in between).

## Contract

**Producer and line.** A bundle is a datadir of the **ycash6** line (`line: "ycash6"`). A ycash-dd node
does not start from it (the two lines' on-disk formats are not promised to agree, plan §4.1); ycash-dd
nodes sync from peers, which is what makes them independent verifiers.

**Network.** One of the testnets of plan Revision 3, named by its datadir: `testnet-yb-fast`,
`testnet-yb-slow`, `testnet-legacy` (`network`); `profile` is the matching `-testnetprofile` (`fast`,
`slow`, `legacy`). The same layout serves `main` later (plan §4.4, N7).

**Height.** `H_B` is a multiple of 1,440 at least 1,000 blocks below the tip when it is picked, and at
least 510,248 (the fork; below it the prefix bundle is the layer). A manual bundle before a release
candidate may name any height above the fork.

**Files.** One directory per bundle:

| File | What |
|---|---|
| `ycash6-<network>-<H_B>-<flavour>.tar.gz` | the datadir, below |
| `manifest.json` | the description, below |
| `statement-<verifier>.json` | one per verifier: `ycash6` (the tarball itself, started offline) and `ycash-dd` (an independent node), at least two |
| `SHA256SUMS` | `sha256sum` format (`<hex>  <name>`) over every other file, sorted bytewise by name |

**Tarball contents.** Every entry is under `<network>/` (the network's directory inside a datadir, so
the tarball extracts into a datadir as is):
- `<network>/blocks/` (block files `blk*.dat`, undo files `rev*.dat`, `blocks/index/`),
  `<network>/chainstate/`, `<network>/vaults/`, `<network>/yellowback/` (the last two when the node has
  them);
- flavour **`full`**: without `blocks/insight-index/`; flavour **`full-insight`**: with it (for
  `-insightexplorer` / `-lightwalletd` nodes such as lightwalletd-dd's backend; the producer then ran with
  `-insightexplorer -txindex`, and so must a node restored from it);
- never: `yellowback/carriers.dat`, `database/`, `wallet.dat` (wallet state); `peers.dat`, `banlist.dat`,
  `onion_private_key`, `debug.log`, `.lock`, `ycash.conf`, `paymentdisclosure/`; LevelDB's `LOCK`, `LOG`
  and `LOG.old` in any directory (recreated by the node; `LOG` holds wall-clock times);
- directories and regular files only: no links, no devices, no absolute path, no `..`.

**Tarball encoding.** GNU tar format; one entry per directory and per file, in bytewise order of their
paths (`LC_ALL=C sort`); every header with mtime 0, uid and gid 0, empty user and group names, mode
`u=rwX,go=rX`; then `gzip -n -6`. In GNU tar terms: `tar --create --no-recursion --format=gnu
--numeric-owner --owner=0 --group=0 --mtime=@0 --mode=u=rwX,go=rX -T <sorted list> | gzip -n -6`. This
removes every variance except the files' own bytes, and LevelDB's file layout differs between two nodes
at the same height: **the tarball is reproducible from the same datadir, not from the same chain**.
That is why the statements, not the tarball, carry the agreement (plan §4.2).

**Blocks above H_B.** The producer stops with `-stopatheight=H_B`, so its chain state is exactly at
`H_B`, but its block files may already hold up to about a thousand blocks above `H_B` that it downloaded
and did not connect. A node started from the bundle connects them (they are ordinary blocks of the
same chain). A consumer that compares the state at `H_B` therefore starts the node offline
(`-connect=0 -listen=0 -dnsseed=0`), and when its tip is above `H_B`, runs `invalidateblock` on block
`H_B + 1`, compares, then `reconsiderblock` on the same block before it goes online, so the datadir keeps
no failed-block mark. The snapshotter's checks do exactly this.

**Statement.** A JSON object with these fields (plan §4.2), canonical: UTF-8, sorted keys, 2-space
indent, one trailing newline:

| Field | From the node at `H_B` |
|---|---|
| `network` | the datadir name above |
| `height` | `H_B` |
| `blockhash` | `getblockhash H_B` |
| `chainwork` | `getblockheader <blockhash>`.`chainwork` |
| `utxo_hash_serialized` | `gettxoutsetinfo`.`hash_serialized` |
| `vault_statehash` | `vault_getinfo`.`statehash` (its `dbtip.hash` must be `blockhash`), `null` when the node has no vault database |
| `yed_statehash` | `yed_getstatehash H_B`.`statehash` (its `blockhash` must be `blockhash`), `null` while the node has no YED module (no attestor set, testnet-legacy) |

Every statement of one bundle is **byte-identical**; the producer refuses to finish otherwise. A
deployment may drop fields from all statements alike (the chart's `snapshotter.statementFields`, for a
field the two lines turn out to compute differently); the remaining ones stay byte-identical, and
`network`, `height` and `blockhash` are always present.

**`manifest.json`.** Canonical as the statement. The statement's fields, plus:

| Field | Value |
|---|---|
| `format` | `"ycash-state/1"` |
| `line` | `"ycash6"` |
| `profile` | `fast`, `slow`, `legacy` (empty for a network without profiles) |
| `version` | the release that produced it, e.g. `6.22.0-rc1` (the node's `getnetworkinfo.subversion` unless the operator names it) |
| `flavour` | `full` or `full-insight` |
| `tarball`, `sha256`, `bytes` | the tarball's name, SHA-256 and size |
| `created` | block `H_B`'s time, `YYYY-MM-DDTHH:MM:SSZ` (UTC): two producers of the same bundle write the same manifest |
| `producer` | `"ycash-infra/snapshotter"` |
| `verifiers` | the statement names, sorted (`["ycash-dd", "ycash6"]`) |

**Signatures.** `SHA256SUMS` is what gets signed (plan §4.2 anchor 3, T-6: the owner's minisign key,
from the private deployment's signing workflow; the verifiers' statement keys come with T-9). Signatures
sit beside it as `SHA256SUMS.minisig` and `statement-<verifier>.json.minisig`, and are not listed in
`SHA256SUMS`. v1 bundles may be published unsigned to a staging location first.

**Where it is published.** An object store per network: `<base>/<network>/<H_B>/<file>`, and
`<base>/<network>/latest/manifest.json` for the newest (plan §4.3: S3 behind a CDN); and, when the
operator turns it on, a GitHub release `state-<network>-<H_B>` with the manifest, `SHA256SUMS` and the
statements (the tarball too while it is under GitHub's 2 GiB asset limit).

## Differences from the plan text (§4.1)

- `network` is the datadir name (`testnet-yb-fast`, ...), not `"testnet"`: there are three testnets
  since Revision 3 and the statement must say which one.
- `created` is the block's time, not the wall clock, so the manifest is reproducible.
- `format`, `profile` and `verifiers` are added; the tarball's entries sit under `<network>/` and LevelDB
  `LOCK`/`LOG` files are left out.
- "Blocks above H_B" above: the plan's check (`ycash-bootstrap` step 6) needs the rollback described
  there, because `-stopatheight` stops the chain state, not the block download.

## Checking a bundle

```bash
python3 -I bundles/state/verify.py DIR      # files, hashes, canonical JSON, statements agree, tar entries and headers
make state-test                             # the snapshotter's steps and verify.py against a stand-in node, offline
```

`verify.py` does not start a node; the state inside the tarball is what the snapshotter's
`restore-check` (and later `ycash-bootstrap`) checks against the statements with a real one.

---

# Mainnet state bundle, format v2 (`ycash-state/2`)

## In plain words

v2 is the same packed datadir as v1, made for **Ycash mainnet** from one machine. v1 cannot hold it
for three reasons:
- mainnet keeps its files at the datadir's root, with no network subdirectory;
- v1 requires a second statement from the other node line (ycash-dd), which takes a separate full
  mainnet sync stopped at the same height. The testnet chart gets that from its `verifier-dd`; a
  single producer cannot;
- v1 has no place for mainnet's own anchors: the block hashes compiled into the node.

v2 adds those anchors instead:
- every compiled ycash6 checkpoint at or below the height;
- a tree hash that ties the tarball, file by file, to the datadir the statement was taken from.

It also adds two optional statement fields that a different node implementation (kogany) can
reproduce. Producer: `bundles/state/mainnet/` (`supervise.py`, `snapshot.py`; procedure in its README).

## Contract

Everything in v1's "Contract" applies, except what follows.

**Network.** `main` (the testnet names stay allowed). `profile` is empty.

**Tarball contents.** Entries sit under `main/` like any v1 network directory, so a tarball never
spills into the working directory and v1's entry rules are checked unchanged. Because mainnet's files
live at the datadir root (ycash6 `src/chainparamsbase.cpp`: mainnet's `strDataDir` is empty), a
consumer extracts with `tar -xzf <tarball> -C <datadir> --strip-components=1`. The tarball encoding
(entry order, fixed headers, `gzip -n -6`) is v1's. The producer writes the tar stream itself
(Python `tarfile`, GNU format) and pipes it through the host's `gzip -n -6`, so the result is
reproducible from the same datadir with the same tools.

**Height.** Any height. The heights captured and why: `bundles/state/mainnet/README.md`.

**Statements.** At least one statement, and `statement-ycash6.json` is required. A v2 statement may
add two fields to v1's:

| Field | From the node at `H` |
|---|---|
| `finalsaplingroot` | `getblock <blockhash> 1`.`finalsaplingroot` |
| `chainsupply_zat` | `getblock <blockhash> 1`.`chainSupply.chainValueZat` (`null` when not monitored) |

The `ycash6` statement comes from an APFS copy-on-write clone of the producer's datadir, taken the
moment the node stopped at `H` (`-stopatheight`). That clone is cloned once more and started offline:
no peers, no listening, its own RPC port. Any block above `H` is rolled back on that throwaway copy,
and the fields are read.

Further verifiers (`ycash-dd`, `kogany`) may be added. As in v1, every statement in a bundle is
byte-identical over the fields the bundle keeps.

**`manifest.json`.** v1's fields with `format: "ycash-state/2"` and
`producer: "ycash-infra/mainnet-snapshot"`, plus:

| Field | Value |
|---|---|
| `commit` | the ycashd commit (`ycashd --version`, e.g. `65cb4ae0f`); `version` is the release (`6.22.0-rc1`) |
| `pins` | `{height: hash}` for every compiled ycash6 mainnet pin at or below `H`: `checkpointData`, the Ycash fork block 570,000, the chain-supply checkpoint block 2,800,000 (ycash6 `src/chainparams.cpp` at 65cb4ae0f; the table is vendored in `verify.py`). Each was read from the node with `getblockhash` and must equal the table |
| `tree_sha256` | SHA-256 over one line `<sha256 of the file>  <path>\n` per regular file of the tarball, in tar order. The producer computes it from the clone while packing; `verify.py --tree` recomputes it from the tarball |
| `treestate` | `"treestate.json"`: `z_gettreestate H` from the same node, canonical JSON, in the bundle directory and in `SHA256SUMS` (the shadow-fork harvest and the kogany sync gate compare it) |
| `purpose` | optional: why this height (e.g. `"proposed shadow-fork height H_S, pending the Yellowback lead architect"`) |

**Files.** The tarball, `manifest.json`, the statements, `treestate.json`, `SHA256SUMS`, and nothing
else. Signatures (`*.minisig`) sit beside them and are not listed, as in v1.

**Where it is published.** As v1: `<base>/main/<H>/<file>` and `<base>/main/latest/manifest.json`.
`latest` only ever moves to a higher height (`bundles/state/mainnet/publish-s3.sh`).

## What v2 does not prove

The UTXO set hash at `H` comes from one implementation (ycash6). The independent anchors are:
- the compiled pins, on the chain the bundle extends;
- proof of work, checked by the node that restores it;
- the sync gate's block-by-block comparison with kogany (hash, Sapling root, chain supply), when a
  `kogany` statement or a `kogany-state/1` bundle at the same height agrees.

A restoring operator who wants more runs `-reindex-chainstate`, which rebuilds the state from the
bundle's own blocks.

---

# kogany state cache, format v1 (`kogany-state/1`)

## In plain words

A packed copy of a stopped kogany (Zakura lineage) node's finalized state database at a height, so
the sync gate (plan W1-Y8) or an operator can resume from it instead of syncing from genesis. Zakura's
database has its own on-disk format version, written in the database's `version` file
(`30.2.0` for kogany at `kogany-legacy` = Zakura `2b062412c5`). **A kogany snapshot is valid only for
that state format.** A kogany build whose `DATABASE_FORMAT_VERSION` major differs opens a different
directory (`state/v<major>/`) and ignores the snapshot. A newer minor or patch version may run its
format upgrade on the copy. Restore a snapshot only into a kogany build of the same state format.

## Contract

- **Source.** kogany's `[state] cache_dir`, with zakurad stopped. At a fixed height the producer
  stops it with `[state] debug_stop_at_height = H`, so the finalized tip is exactly `H`. At the
  network tip it is stopped at its tip `H`. The blocks above its finalized tip then sit in the non-finalized
  state, which kogany restores from `non_finalized_state/` on reopen.
- **Tarball** `kogany-main-<H>-state-<state_format>.tar.gz`. Entries sit under
  `state/v<major>/mainnet/` (relative to `cache_dir`). They include every RocksDB file: `*.sst`,
  `*.log` (the write-ahead log, which holds data), `CURRENT`, `IDENTITY`, `MANIFEST-*`, `OPTIONS-*`
  and `version`. They exclude `LOCK`, `LOG` and `LOG.old.*`, the peer cache (`network/`),
  `identity/` and logs.
- **The non-finalized state** (`non_finalized_state/mainnet/`, one file per block above the
  finalized tip) is **required whenever the cache has any**: without it a tip snapshot's state would
  end below its `height`. Its file count is the manifest's `non_finalized_blocks`, and
  `verify.py` checks it against the tarball. A bundle without the field counts as 0. The first four
  bundles (`debug_stop_at_height`, finalized tip exactly at `H`) were packed without the directory
  and have no such field.
- **Encoding.** v1's: bytewise order, fixed headers, `gzip -n -6`.
- **`manifest.json`** (canonical as above):
  - `format: "kogany-state/1"`, `line: "kogany"`, `network: "main"`;
  - `height`, `blockhash` (from the node or the sync gate at `H`), `state_format`;
  - `tarball`, `sha256`, `bytes`, `tree_sha256` (as in v2);
  - `producer`, `version` (the kogany commit or release that wrote it);
  - `non_finalized_blocks`: the number of non-finalized block files included;
  - `agrees_with`: `"ycash6:<sha256 of statement-ycash6.json>"` when the producer checked that the
    `ycash-state/2` statement at the same height names the same block hash; `null` otherwise.
  - At a pinned height, `blockhash` must equal ycash6's pin.
- **`SHA256SUMS`** over the tarball and the manifest.
- **Published** at `<base>/kogany-main/<H>/<file>` and
  `<base>/kogany-main/latest-<state_format>/manifest.json`.
- **Restore**: stop kogany, then
  `tar -xzf <tarball> -C <cache_dir> && cat <cache_dir>/state/v*/mainnet/version`, where
  `<cache_dir>` is kogany's `[state] cache_dir`. The version must equal `state_format`.
