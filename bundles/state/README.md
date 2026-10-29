# bundles/state — the testnet state bundle

## In plain words

A state bundle is a packed, checked copy of a Ycash testnet node's working files at an agreed block,
so a new node starts in minutes instead of syncing for hours. Two different node programs must agree
on its fingerprints before it is published. [FORMAT.md](FORMAT.md) is the exact layout.

| What | Where |
|---|---|
| The format (`ycash-state/1`) | [FORMAT.md](FORMAT.md) |
| The producer: the snapshotter and bundle verifier | `charts/ycash-testnet` `snapshotter` (CronJob), its steps in `charts/ycash-testnet/files/snapshot.sh` |
| An offline checker of a bundle directory | `verify.py` (`python3 -I bundles/state/verify.py DIR`) |
| Tests: every snapshotter step against a stand-in node, `verify.py` | `tests/` (`make state-test`) |
| The consumer (restore into a datadir) | `ycash-bootstrap` in the node repositories (testnet plan §4.4, N2) |

The snapshotter has not yet run against a real node: the steps are tested with the stand-in in
`tests/mocknode`, and the node's own `-stopatheight` is tested in the node repositories
(`qa/rpc-tests/stopatheight.py`).
