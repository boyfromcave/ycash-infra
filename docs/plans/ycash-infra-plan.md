# ycash-infra — the light-wallet backend on Kubernetes: plan

**Revision 1 (2026-10-08).** From the ideation document in the workspace
(`docs/ideation/yellowback-web-wallet-and-k8s-plan.md`, branch `ideation/web-wallet`) and the
owner's answers to its eight questions, the same day. The web wallet's plan is `yew/docs/plans/yew-web-plan.md`.

## 0. Owner decisions (2026-10-08)

| # | Decision | Answer |
|---|---|---|
| I-1 | Custody | **Non-custodial.** Keys in the browser; the cluster never sees a seed, a key or an unsigned transaction. |
| I-2 | Web shell home | **`yew/web`** inside `yew`, one core, one CI; a working branch off `upgrade/vault` (the in-term branch `upgrade/vault-in-term` is to be merged there first, owner). |
| I-3 | Web scope | **Sapling from day one.** Not transparent-first. |
| I-4 | Browser storage | **sqlite-wasm over OPFS**, keeping rusqlite and `zcash_client_sqlite`; not an IndexedDB rewrite. |
| I-5 | Deployment repo | **`ycash-infra`, default branch `upgrade/vault`.** |
| I-6 | Gateway | **Envoy Gateway** (Gateway API). |
| I-7 | Index | **Build `yindex` now**, not after measurement. The measurement (K1) still runs, to size the node pool. |
| I-8 | `lite.ycash.xyz` | **Not yet.** This chart serves a second endpoint until the owner moves the public one. |

Also decided by the owner during the first session: **official Docker images for both node
lines live in the node repos** (`ycash6/contrib/docker/ycashd/`, `ycash-dd/contrib/docker/ycashd/`),
built and tested on this machine before anything is pushed; the regtest configuration is in
the entrypoint and a compose file beside each Dockerfile.

## 1. Architecture

See README.md ("What runs, and what is shared"). In one sentence: identical, share-nothing
replicas at every tier behind a load balancer, the chain replicated by the Ycash protocol, the
gateway routing gRPC by method so the three address methods go to the index and everything else
to `lightwalletd-dd`; no node change, no lightwalletd change, no new RPC surface.

### 1.1 Why the index is allowed (contract rule 3 and D-L-2)

The lightwalletd plan's D-L-2 is "proxy, not indexer" and contract rule 3 says a Yellowback
verdict is the node's. `yindex` indexes only the **stock transparent address data** (outputs,
spends, raw transactions), the same thing the node's `-insightexplorer` index holds; it answers no
`YellowbackStreamer` method, never classifies a `"YB"` payload, and never computes a YED token
set. `GetAddressTokens` stays a proxy of `yed_listtokens`, cached per `(address, tip hash)` in
Redis (K3b), which keeps the node the single source of every verdict and turns per-user polling
into per-block work.

### 1.2 Ycash regtest in a cluster

The vault upgrade activates on regtest with `-nuparams=6d5b7a31:<h>`; the kind values set
`YCASHD_VAULT_HEIGHT=1`. YED on regtest additionally needs an attestor set created on chain and
the node restarted with `-yellowbackattestorset=<setid>`, which the devnet's `up` does across
eight nodes with real attestor agents. K0 does not arm YED; K0b ports the arming recipe as a
Job (one node, one set, the restart done by patching the StatefulSet's env and rolling it).

## 2. Phases

| Chunk | Content | Acceptance | Status |
|---|---|---|---|
| **K0** chart on kind | images from the node and lightwalletd repos; Helm chart; kind config; Envoy Gateway + cert-manager; regtest bootstrap + miner; `scripts/smoke.sh` | `make kind-up && make kind-smoke` green: `GetLightdInfo`, `GetLatestBlock`, `GetVaultInfo`, `GetChainInfo`, a gRPC-web request answered | files written 2026-10-08; **not yet run** (node image building) |
| **K0a** node images | `contrib/docker/ycashd/` in `ycash6` and `ycash-dd`: Dockerfile, entrypoint, regtest compose, README | both images build on this machine; each runs regtest, mines, reports `6d5b7a31` active in `getblockchaininfo.upgrades` | in progress 2026-10-08 (builds running) |
| **K0b** arm YED on kind | the devnet `up` arming recipe as a Job; `GetYellowbackInfo` live | `GetYellowbackInfo.upgrade.status` live; `GetAddressTokens` answers | not started |
| **K1** measurement | `load/run.sh`: ghz per method through the gateway, node RPC queue depth watched | the ceiling per method recorded in §4 | not started |
| **K2** EKS | `infra/eks` applied; add-ons; ECR push; `values-eks.yaml` on a real cluster; RDS for yindex | smoke green on the public host; YEW's devnet suites pointed at it | not started |
| **K3** yindex live | ingester + server (written) routed by the gateway; reorg test on kind; parity test against lightwalletd's node-proxied answers | `GetAddressUtxos`/`GetTaddressTxids`/`GetTaddressBalance` from yindex equal lightwalletd's for every address the regtest suite touches, across a reorg | code written 2026-10-08, untested |
| **K3b** verdict cache | a tip-hash-keyed Redis cache for `yed_*` reads inside `lightwalletd-dd`'s `CallYed` (its repo; small, reviewable) | per-block, not per-user, node load for `GetAddressTokens` | not started; needs a lightwalletd-dd change |
| **K4** web bundle | `yew/web` dist served by the gateway with the CSP/COOP/COEP headers | the web wallet syncs and sends on kind | after `yew/web` W1 |

## 3. Interfaces

- Clients → gateway: the four gRPC services of `lightwalletd-dd/walletrpc` (unchanged), over
  TLS gRPC (native apps) or gRPC-web (browser).
- Gateway → yindex: `CompactTxStreamer.{GetAddressUtxos, GetAddressUtxosStream, GetTaddressTxids,
  GetTaddressBalance, GetTaddressBalanceStream}` only (`values.yaml` `yindex.routes`).
- yindex → node: `getblockcount`, `getblockhash`, `getblock <hash> 2`. Read-only, stock.
- lightwalletd → node: as upstream. Nothing new.

## 4. Measurements (K1)

| Method | rps at p99 < 500 ms | node RPC queue at that rate | date, image |
|---|---|---|---|
| (to be filled by `load/run.sh`) | | | |

## 5. Node asks (recorded, not scheduled)

- A-1: `yed_listtokens` returning the tip hash it answered at, so the K3b cache key is exact
  rather than read in a second call.
- A-2: `getblock` verbosity 2 includes `valueZat`; confirm on both lines (`valueSat` fallback in
  `rpc/client.go`).

## 6. Risks

- Envoy Gateway's gRPC-web is applied as an `EnvoyPatchPolicy` (its native option is still
  tracked upstream); the patch targets the listener name and must be re-checked on each EG upgrade.
- Two nodes briefly disagree at the tip during a reorg: the readiness probe's lag check hides a
  node a block behind, and the clients rewind 10 blocks. K3's reorg test covers yindex.
- Building the node image from source is 1–2 h per line per architecture; a GitHub release
  tarball (Dockerfile.release in the node repo, to add once 6.22.0 ships) makes it minutes.
