# images/prefix-frame — the testnet prefix restore

## In plain words

A new Ycash testnet node starts from a copy of Zcash testnet's early history (blocks 0 to 510,247,
the "prefix", `bundles/prefix/FORMAT.md`). This image downloads that copy, checks it is exactly the
copy the Ycash developers signed, and rewrites it into block files the node can import. Nothing in
the copy is ever run; the image holds no secret, only the public release key.

## What it does

`charts/ycash-testnet` runs it as both prefix init containers (`prefixRestore`):

| Command | What |
|---|---|
| `prefix.sh fetch` | `prefix-restore.sh` (a copy of `charts/ycash-testnet/files/prefix-restore.sh`): `SHA256SUMS` must hash to `PREFIX_SUMS_SHA256`, every file must check, the manifest must be `ycash-prefix/1` `zcash-testnet` 0..`PREFIX_LAST_HEIGHT`; then `SHA256SUMS.minisig` must verify against `/opt/prefix/ycash-release.pub` (`keys/ycash-release.pub`, key id `02C923A6C593AF18`). Writes `VERIFIED` and `SIGNED`; a bad signature removes `VERIFIED` and exits 1 |
| `prefix.sh frame ARGS…` | `python3 -I frame.py ARGS…` (`bundles/prefix/import/frame.py`): the chunks to `blk-*.dat` `-loadblock` files with the network magic |

Base `python:3.12-alpine` by digest, plus `curl jq coreutils minisign` from Alpine; UID 2001 (the
node images'). `PREFIX_MINISIGN_PUB` and `PREFIX_CURL_PROTO` (default `=https`) exist for local
tests only.

## Build and publish

```bash
make image-prefix-frame          # ycash/prefix-frame:local, context the repository root
```

`.github/workflows/prefix-frame-image.yml` (by hand, from `upgrade/vault`) pushes
`ghcr.io/<owner>/ycash-prefix-frame:<sha12>` with provenance and prints the digest for
`values-eks.yaml` `images.prefixFrame.digest`.

## What the published bundle must hold

Flat under `prefixRestore.baseUrl`: `SHA256SUMS`, `SHA256SUMS.minisig` (by the release key) and
every file `SHA256SUMS` lists (`manifest.json` and the `.blocks.gz` chunks), nothing else needed.
