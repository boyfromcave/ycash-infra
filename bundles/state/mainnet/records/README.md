# Recorded mainnet snapshots

One directory per captured height. Each holds the bundle's `manifest.json`, `statement-ycash6.json`,
`treestate.json` and `SHA256SUMS`, plus the supervisor's `capture.json` (when the node stopped and how
long it was paused).

The tarballs are not in git:
- `SHA256SUMS` names a tarball that is not here, and its `sha256` and `bytes` are in the manifest;
- the tarballs are published to the object store (`../publish-s3.sh`), or rebuilt byte for byte from
  the capture's clone (`snapshot.py pack`).

`kogany/` beside a height holds that height's `kogany-state/1` manifest and sums, when there is one;
`kogany-pruned/` a pruned `kogany-state/2` bundle's (the tip only, so far).

`tip-<H>-insight/` holds a `full-insight` bundle (transaction and insight explorer indexes), published
under `main-insight/<H>/`.
