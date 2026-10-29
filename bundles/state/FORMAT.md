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
