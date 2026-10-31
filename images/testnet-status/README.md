# images/testnet-status — a testnet's probe and status page

## In plain words

Each Ycash testnet gets a small public web page that says whether it is healthy: how high the chain
is, when the last block came, how many peers the nodes have, whether the vault upgrade is active,
which attestor set runs Ycash Yellowback (YED), which release is being tested, the latest downloadable
snapshot, and any notice about a planned reset. Behind it, a "probe" asks every node of that network
the same questions every 30 seconds, checks that the different node programs agree on every block and
on the vault and YED state, and checks that each seed machine answers. The probe feeds the alerts the
operators get; the page shows only harmless numbers and holds no password.

## What runs

One image, two commands (`charts/ycash-testnet` `probe` and `status`):

| Command | Holds | Serves | To |
|---|---|---|---|
| `probe.py` (default) | the network's RPC credential | `/metrics` (Prometheus), `/status.json` (public numbers only), `/healthz` on 9100 | Prometheus and the status page, inside the cluster (NetworkPolicy) |
| `status.py` | nothing secret | the page (`index.html`, `status.js`), `/status.json` (the probe's summary plus the release and the notices), `/healthz` on 8080 | the public, through the gateway (exact paths only), with a strict Content-Security-Policy |

The probe, per round: `getblockchaininfo`, `getblockheader`, `getconnectioncount`, `getchaintips`,
`getnetworkinfo`, `vault_getinfo`, `yed_getstatehash` on every node in `NODES`; `getblockhash` at the
nodes' common height (do they hold the same block?); the vault and YED state hashes between nodes whose
state is at the same block (the testnet plan §6.4 cross-line check: ycash6 against ycash-dd); a P2P
`version` message to every seed in `SEEDS`, answered in this network's magic (`MAGIC`) or not; the
latest state bundle's manifest (`BUNDLE_MANIFEST_URL`). Its metrics:

| Metric | Meaning |
|---|---|
| `ycash_node_up`, `ycash_node_height`, `ycash_node_headers`, `ycash_node_peers` | per node (`node`, `line`) |
| `ycash_node_tip_timestamp_seconds` | the tip's block time (tip age = now minus this) |
| `ycash_node_fork_length` | the longest valid side branch within 10 blocks of the tip |
| `ycash_node_info`, `ycash_vault_activation_height`, `ycash_vault_active`, `ycash_vault_attestor_set_info` | version, profile, the vault upgrade, the attestor set |
| `ycash_nodes_tip_agree` | 1 when every node holds the same block at their common height |
| `ycash_statehash_agree{kind="vault"\|"yed"}` | 1 when nodes at the same block agree; absent when fewer than two can be compared |
| `ycash_seed_up`, `ycash_seed_handshake_seconds` | per seed |
| `ycash_bundle_height`, `ycash_bundle_created_timestamp_seconds`, `ycash_bundle_manifest_ok` | the latest state bundle |
| `ycash_probe_last_round_timestamp_seconds` | the probe itself |

Python's standard library only. Tests (stand-in nodes and seeds, offline): `make services-test`.
Build: `make image-testnet-status` (`ycash/testnet-status:local`); no published image yet.
