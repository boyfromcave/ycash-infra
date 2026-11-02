# Mainnet snapshots (`ycash-state/2`, `kogany-state/1`, `kogany-state/2`)

## In plain words

A Ycash mainnet node takes many hours to sync from scratch. These tools pause a node that is already
syncing for a few seconds at a list of agreed blocks, copy its files at each one, and pack every copy
into a checked bundle. The bundles have three uses:
- an operator can start a node in minutes instead of hours;
- the practice networks that copy mainnet's history (testnet-yb-slow and testnet-legacy, the "shadow
  fork") have a ready source at the split block;
- the new Rust node (kogany) can be compared with the current node at the same blocks.

Nothing here changes the node. It uses `-stopatheight`, the `stop` RPC and the read RPCs.

| What | Where |
|---|---|
| The format | [../FORMAT.md](../FORMAT.md), "format v2", "kogany-state/1" and "kogany-state/2" (archive or pruned) |
| Pause the node at each height, clone its files | `supervise.py` |
| Statement, tarball, manifest, verify | `snapshot.py` (`all`, or `statement`, `pack`, `finalize`; `kogany`) |
| Check a bundle | `python3 -I ../verify.py --tree DIR` |
| Upload one bundle to S3 | `publish-s3.sh DIR s3://bucket/prefix` |
| The manifests of the snapshots taken so far (no tarballs) | `records/<H>/` (`manifest.json`, `statement-ycash6.json`, `SHA256SUMS`, `capture.json`) |
| Offline tests | `../tests/test_mainnet.py` (`make state-test`) |

## The heights, and why

| Height | Why |
|---|---|
| 570,000 | The Ycash fork block (`UPGRADE_YCASH.hashActivationBlock`, pinned in ycash6 and in kogany's checkpoint list). The last shared Zcash block is 569,999; the state here is the first Ycash state. kogany's checkpoint list (W1-Y4) and the sync gate's activation boundaries (`569,999 / 570,000 / 570,001`) meet here |
| 1,100,006 | Canopy activation (Blossom 1,100,000, Heartwood 1,100,003). kogany's W1-Y4 gate is checkpoint sync from genesis to 1,100,005, and from Heartwood the sync gate compares the ZIP-221 history root. A snapshot just past the three upgrades lets the gate restart at the epoch where the comparison changes |
| 2,275,000 | `nYdfMandateEndHeight`: the end of the Ycash Development Fund's mandatory output. Coinbase rules change here, so a block-by-block comparison of kogany against ycash6 wants a restart point on each side of it |
| 2,800,000 | The chain-supply checkpoint (`nChainSupplyCheckpointHeight`, block pinned, the supply totals compiled in). Its statement's `chainsupply_zat` must equal ycash6's compiled `nChainSupplyCheckpointTotalSupply` (1,656,148,924,247,473) |
| 3,079,999 | **The shadow-fork height H_S (decided by the Yellowback lead architect, 2026-11-02; the manifest's `purpose` still says "proposed" because it was written at capture time and is covered by the recorded sums).** The shadow-fork plan's rule: the last copied block is k × 10,000 − 1, at least 1,000 blocks below the tip when the harvest runs; the network tip was 3,087,068 on 2026-11-02. A state bundle here is the starting state of testnet-yb-slow and testnet-legacy, and it is where `mainnet-prefix-v1` ends. If the lead architect picks another H_S, the tip snapshot or a new capture serves instead |
| the tip | For operators: the newest state, taken once the node is synced (the `stop` RPC at the tip; the height is whatever the tip was) |

H_B for testnet bundles follows FORMAT v1's 1,440-block rule. Mainnet heights are chosen, not
periodic: every snapshot here is either an epoch boundary another tool compares at, or the tip.

## The procedure (what was run)

1. **Supervise** the node that is already syncing. The supervisor adopts it: a clean `stop`, then a
   restart with the same datadir and flags plus `-stopatheight=<next height>`.

   ```bash
   nohup python3 -I supervise.py --datadir $WS/wt/.data/ycash-mainnet --bin $WS/wt/.bin/ycash6-65cb4ae0f \
     --snapdir $WS/wt/.snapshots/ycash-mainnet --heights 570000,1100006,2275000,2800000,3079999 \
     --tip --tip-settle 1800 --node-arg=-optimize-getheaders=0 >> supervise.log 2>&1 &
   ```

   At each height the node stops by itself with its chain state exactly at H; `-stopatheight`
   connects nothing above it. The supervisor then clones `blocks/`, `chainstate/`, `vaults/` (and
   `yellowback/` when present) into `<snapdir>/<H>/datadir/main/` with `cp -c`, an APFS
   copy-on-write clone: seconds, and almost no disk, because the clone shares every extent with the
   live datadir until the node rewrites a file. Then it restarts the node towards the next height.
   The pause is the shutdown plus the clone plus the restart, recorded in `<H>/capture.json`. After
   the last fixed height the node syncs to the tip; once it has reported itself synced for 30
   minutes it is stopped, cloned into `tip-<height>/` and started a final time without
   `-stopatheight`.

   `-optimize-getheaders=0`: the datadir had been through a disk-full crash and a `-reindex`, and
   kept a stale header chain. With the default optimisation, ycashd stops asking a peer for headers
   when the last header of a full batch is already known. Its best header was stuck below its own
   tip, so it asked from there, got 160 headers it already knew, and stopped: block download stalled
   at 345,319. The flag is the node's own documented escape hatch (`src/main.cpp`, "Allow disabling
   optimization"); it changes no rule.
2. **Bundle** each capture, while the node syncs on:

   ```bash
   python3 -I snapshot.py all --capture <snapdir>/<H> --bin $WS/wt/.bin/ycash6-65cb4ae0f [--purpose "..."]
   ```

   - `statement`: a second clone, started offline (port 18252, no peers). Any block above H is rolled
     back with `invalidateblock` on that throwaway copy only. The step reads the hash, chainwork,
     `gettxoutsetinfo`, `vault_getinfo`, `yed_getstatehash`, the Sapling root and the chain supply at
     H, checks every compiled pin at or below H, and writes `z_gettreestate H`.
   - `pack`: the tarball from the untouched clone, and its tree hash.
   - `finalize`: `manifest.json` and `SHA256SUMS`.
   - Then `verify.py --tree`.
3. **Record** `manifest.json`, `statement-ycash6.json`, `SHA256SUMS` and `capture.json` under
   `records/<H>/`. Never the tarball.
4. **Disk.** The clones cost little; a tarball costs about the datadir's size at H. Keep at least 40
   GB free. Once a bundle is verified and recorded, its tarball may be deleted locally: the clone
   stays, and it reproduces the tarball byte for byte (`snapshot.py pack`, same tools), which the
   recorded `sha256` then confirms.

### kogany

kogany's sync-gate driver (W1-Y8) owns the kogany node; nothing here starts it. For a snapshot at H
the driver runs kogany with `[state] debug_stop_at_height = H` (Zakura `zakura-state` config). The
finalized state then stops exactly at H and zakurad exits. Then:

```bash
python3 -I snapshot.py kogany --cache $WS/wt/.data/kogany-mainnet/state --height H --blockhash <hash at H> \
  --out <snapdir>/<H>/kogany --version <kogany commit> --ycash-statement <snapdir>/<H>/bundle/statement-ycash6.json
```

`--cache` is kogany's `[state] cache_dir`: the directory holding `state/v30/mainnet` and
`non_finalized_state/mainnet`. In practice, clone it first with `cp -c` (seconds) and pack the
clone, so kogany can resume at once. The bundle records the
state format (`30.2.0`) from the database's `version` file, and is valid only for that format
(FORMAT.md). It also includes the non-finalized blocks whenever there are any (a tip snapshot). The
bundle is `kogany-state/2` and names its storage mode: `--storage-mode archive` (the default) for a
cache written in Archive mode.

**A pruned bundle beside the archive one** (FORMAT.md "kogany-state/2"; workspace pruning
assessment, decisions 6 and 8): clone the stopped cache, prune the clone offline with the same
kogany build's `zakura-prune-state`, and pack it with the lowest retained height the prune printed:

```bash
cp -c -R $WS/wt/.data/kogany-mainnet/state <scratch>/state
zakura-prune-state --cache-dir <scratch>/state --network mainnet --tx-retention 34560 --confirm
python3 -I snapshot.py kogany --cache <scratch>/state --height H --blockhash <hash at H> \
  --out <snapdir>/<H>/kogany-pruned --version <kogany commit> \
  --storage-mode pruned --lowest-retained-height <the summary's "new lowest retained height">
```

Restore a pruned bundle only into a kogany configured `[state.storage_mode.pruned] tx_retention = N`
(N at least 10,000): Zakura refuses to open it in Archive mode.

## Publishing (for the chart's snapshotter and the restore)

`publish-s3.sh DIR s3://<bucket>/<prefix>` uploads one verified bundle:
- `ycash-state/2`: to `<prefix>/main/<H>/`, then `<prefix>/main/latest/manifest.json` when H is the
  newest;
- `kogany-state/1` and archive `kogany-state/2`: to `<prefix>/kogany-main/<H>/` and `latest-<state_format>/`;
- pruned `kogany-state/2`: to `<prefix>/kogany-main-pruned/<H>/` and `latest-<state_format>/` there.

This is the layout `charts/ycash-testnet` `snapshot.sh publish-s3` uses, with `main` as the network.
The script refuses to overwrite a published height and uploads the manifest and `SHA256SUMS` last.
Credentials come from the caller (the private deployment's role); nothing is uploaded from this
machine.

Before publishing, sign `SHA256SUMS` with the release key (`SHA256SUMS.minisig`, ycash-ops
`sign-release`, plan T-6), as for every bundle. `DRY=1` prints the commands.

## Restoring a node from a mainnet bundle

```bash
B=https://<cdn>/<prefix>/main/latest            # or .../main/<H>
curl -fsSO $B/manifest.json; curl -fsSO $B/SHA256SUMS; curl -fsSO $B/SHA256SUMS.minisig
minisign -Vm SHA256SUMS -p ycash-release.pub      # the release key (ycash-ops keys/ycash-release.pub)
T=$(python3 -c 'import json; print(json.load(open("manifest.json"))["tarball"])')
curl -fsSO $B/$T; curl -fsSO $B/treestate.json; curl -fsSO $B/statement-ycash6.json
sha256sum -c SHA256SUMS                           # every file, the tarball included
python3 -I verify.py --tree .                     # optional: entries, headers, pins, tree hash
ycash-cli stop                                    # if a node runs on the datadir
mkdir -p ~/.ycash && tar -xzf $T -C ~/.ycash --strip-components=1
ycashd -datadir=$HOME/.ycash                      # with your own ycash.conf
ycash-cli getblockhash <H>                        # must equal the manifest's blockhash
```

- The datadir must be empty of `blocks/` and `chainstate/` before the extract. The bundle carries no
  wallet, no `peers.dat` and no `ycash.conf`.
- The node connects the blocks the bundle holds above H, then syncs on from peers.
- A node that wants to recheck the state rather than trust it starts once with
  `-reindex-chainstate`, which rebuilds the UTXO set from the bundle's blocks: hours, not days, and
  no download.
- For the chart: the init container does the same from `<base>/main/latest/manifest.json`, as for
  the testnets (`ycash-bootstrap`, testnet plan §4.4).

## Taken on 2026-11-02 (ycash6 6.22.0-rc1 at 65cb4ae0f)

All bundles below are `verify.py --tree` ok. Each node pause was the clone (0.1–0.5 s) plus the
node's restart. The tarballs of the checkpoint heights were deleted after recording; each rebuilds
byte for byte from its clone, which was shown for 570,000. The H_S and tip tarballs are kept for
publishing.

| Height | Block | `utxo_hash_serialized` | Tarball bytes | Tarball sha256 |
|---|---|---|---|---|
| 570,000 | `0000014fbc59…50c77ec5` (pin) | `c94ae436…80048406` | 18,938,433,104 | `3ea2693c…976c02e3` |
| 1,100,006 | `00000388cfe0…612205d5` | `228377fa…c9f2ec2c` | 20,591,711,514 | `94af4b3f…5fc35ff4` |
| 2,275,000 | `000006e55442…02c9183c` | `b9f2e313…edbd8367` | 23,358,662,189 | `8258fe3b…7287b690` |
| 2,800,000 | `000003170414…3874facb` (pin; supply = compiled total) | `af80d206…7b24473a` | 24,187,791,474 | `7aa4c0d2…56cf006d` |
| 3,079,999 (proposed H_S) | `000005030be4…d31e4bef` | `58b9a13c…07968509` | 24,453,443,316 | `7f09ffe2…574ee45c` |
| 3,087,294 (tip) | `0000014ff36f…7ac3eeee` | `dcc2265d…1601beff` | 24,444,609,639 | `d7f7ecbf…35228d38` |

The full values are in `records/<H>/`.

kogany 1.7.0+383.g081e264c2 (`kogany-state/1`, Zakura state format 30.2.0):
- The sync-gate driver stopped it with `debug_stop_at_height` at each fixed height, and with the
  `stop` at its tip. Each block equals ycash6's at the same height (`agrees_with` names ycash6's
  statement there).
- The tip's block equals the live ycash6 node's `getblockhash 3087341`; ycash6 has no statement at
  that height.
- Only the H_S and tip tarballs are kept.

| Height | Block | Tarball bytes | Tarball sha256 | Non-finalized blocks |
|---|---|---|---|---|
| 570,000 | `0000014fbc59…50c77ec5` | 18,397,165,478 | `86c48395…50075071` | 0 |
| 1,100,006 | `00000388cfe0…612205d5` | 19,680,987,591 | `c291c43f…e1de90b7` | 0 |
| 2,275,000 | `000006e55442…02c9183c` | 21,241,831,647 | `dc88e245…53528322` | 0 |
| 2,800,000 | `000003170414…3874facb` | 21,885,176,031 | `61b83b72…150e09ae` | 0 |
| 3,079,999 (proposed H_S) | `000005030be4…d31e4bef` | 22,429,729,018 | `e74668ed…325311df` | 0 |
| 3,087,341 (tip) | `0000002ba6d9…338461bf` | 22,206,647,600 | `484ad481…bcd68fad` | 1,001 |

The kogany manifests are in `records/<H>/kogany/` (the tip: `records/kogany-tip-3087341/kogany/`).

The pruned pair at the tip (`kogany-state/2`, 2026-11-02): a clone of the tip cache above, pruned
offline with `zakura-prune-state --tx-retention 34560` (the kogany `kc/pruned` build, the same state
format 30.2.0), then packed. The prune kept raw transactions from 3,051,782 (finalized tip 3,086,341
minus 34,560, plus one) and took the state directory from 24 GB to 6.7 GB in 104 s (a debug build); packing took four
minutes. The clone opened in Pruned mode (offline, no peers) at the tip, `getblockchaininfo`
`"pruned": true`, `"pruneheight": 3051782`, `getblock` below it answered `-32603 Block not available
(pruned data)` at every verbosity and above it the block; the same clone in Archive mode was refused
at start ("this database has been pruned and cannot be opened in archive storage mode").

| Height | Block | Mode | Lowest retained | Tarball bytes | Tarball sha256 | Non-finalized blocks |
|---|---|---|---|---|---|---|
| 3,087,341 (tip) | `0000002ba6d9…338461bf` | archive (`kogany-state/1`) | all | 22,206,647,600 | `484ad481…bcd68fad` | 1,001 |
| 3,087,341 (tip) | `0000002ba6d9…338461bf` | pruned (`kogany-state/2`) | 3,051,782 | 5,429,931,325 | `79035357…01dcdb73` | 1,001 |

Its manifest is in `records/kogany-tip-3087341/kogany-pruned/`.
