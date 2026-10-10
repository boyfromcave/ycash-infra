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

A set alone is `attest UNARMED` and `NO_PRICE`: nothing is mintable. What takes the one-node chain
from "set exists" to mintable (K0c, the devnet's `up` for one node; `scripts/kind-personas.py`):

1. **The pool.** Quotes ride in coinbase tags, and a node tags only with a payout key
   (`-yellowbackpayoutaddress`, MINER-2). The arming Job records `getnewaddress` of the node's
   wallet in ConfigMap `<release>-yellowback-set` (`payoutaddress`); the StatefulSet template reads
   it with `lookup` and appends the flag, so the node is the pool after the next `helm upgrade`
   (`kind-up.sh` runs one after the Job). The chart's miner `generate`s on that node: every block
   it mines carries the node's quote tag, so no stratum path and no second miner are needed.
2. **The quote.** `yellowback-quote --mock-price` beside the node (loopback RPC; `yed_setquote`
   every 5 s), then `generate` until `yed_getstats.haltMask` loses `NO_PRICE` (the slow window
   needs 43 quote tags of 64: ~70 blocks from cold, 20 on a chain that already had tags).
3. **The attestors.** `yed_registerattestor 10 200` three times from the node's wallet (a
   `SET_JOIN` each; a block and a 2 s settle between them, the devnet's gotcha), 8 blocks
   (`BOND_MATURITY`) → `TRIGGERED`, 8 more (`ATTEST_ARM_DELAY`) → `ARMED`. All three member keys
   live in the one wallet; the equivocation guard is per seq, so one node signs for three seqs.
4. **The attestations.** One `yellowback-attest attest --mock-price` per seq and one `subscribe`
   beside the same node, `dir` transport (`~/.local/state/ycash-infra/personas/bus`); the agents
   sign every 4 blocks, so `ATTEST_INTERVAL + REF_LAG` blocks later `poolFresh >= M_SELECT`.
5. **The walk.** A constant quote beside moving attestations is pinned (PIN-1); the quote's and the
   attestors' mock prices take the same small random step every 5 s inside a ±10 % band.

The chart's miner is the heartbeat. `make kind-personas-up` does 1–5 and is resumable (a
`helm upgrade` from a chart without the lookup — another agent's older tree — restarts the node
without the flag; `up` again re-applies it, the agents it finds alive are kept); `down` stops the
agents and leaves the chain `ARMED` (minting halts once the attestations are older than
`ATTEST_MAX_AGE`, and resumes within seconds of the next `up`).

## 2. Phases

| Chunk | Content | Acceptance | Status |
|---|---|---|---|
| **K0** chart on kind | images from the node and lightwalletd repos; Helm chart; kind config; Envoy Gateway + cert-manager; regtest bootstrap + miner; `scripts/smoke.sh` | `make kind-up && make kind-smoke` green: `GetLightdInfo`, `GetLatestBlock`, `GetVaultInfo`, `GetChainInfo`, a gRPC-web request answered | **run 2026-10-08 on kind (arm64)**: cluster, Envoy Gateway, cert-manager, regtest node, bootstrap (200 blocks), miner, 2× lightwalletd-dd, yindex, Redis, Postgres all up; `GetLightdInfo`/`GetLatestBlock` over TLS through the gateway, gRPC-web answered (HTTP 200 `application/grpc-web+proto`); `YellowbackStreamer` absent until K0b (the node registers `yed_*` only with an attestor set). Fixed on the way: GatewayClass must be created by the chart, lightwalletd readiness is `/metrics`, the gRPC-web patch path is `/filter_chains/0/...`, ycash-cli in Jobs needs `-conf=/dev/null -regtest` |
| **K0a** node images | `contrib/docker/ycashd/` in `ycash6` and `ycash-dd`: Dockerfile, entrypoint, regtest compose, README | both images build on this machine; each runs regtest, mines, reports `6d5b7a31` active in `getblockchaininfo.upgrades` | **ycash6 done 2026-10-08** (18 min build on M-series, image 6.22.0-rc1; regtest mines, `upgrades.Vault.status = active`, `consensus.nextblock = 6d5b7a31`); **ycash-dd done 2026-10-08** too (aarch64 needed `libxml2` for the depends `ld.lld` and a libc++ include alias for boost; params fetched on first start; regtest mines, Vault active); both images rebuilt from the `upgrade/vault` heads of the day (ycash6 `b3ae528`, ycash-dd `f24a691`, lightwalletd-dd `c8346c3`) and the kind smoke + yindex parity re-run green on them |
| **K0b** arm YED on kind | the devnet `up` arming recipe as a Job; `GetYellowbackInfo` live | `GetYellowbackInfo.upgrade.status` live; `GetAddressTokens` answers | **done 2026-10-09 on the live kind cluster** (`helm upgrade`, no cluster rebuild): `regtest.armYellowback` (kind only) adds `templates/kind/arm.yaml`: ServiceAccount + Role + Job `<release>-arm-yellowback`. Init container `set` (node image, ycash-cli against the RPC Service): wait for the bootstrap height, `set_create {seats 15, unlockthreshold 1, cancelthreshold 1, slashthreshold 1, open, maturity 1, bondmin 10, bondlockmin 200, livenesswindow 1000}` from the node's wallet, `generate 1`, `set_getinfo` until it exists, `getnewaddress` + `dumpprivkey` for one attestor key. Container `roll` (`bitnami/kubectl`, kubectl + curl + jq): ConfigMap `<release>-yellowback-set` (`setid`, read by the StatefulSet's `YCASHD_YELLOWBACK_ATTESTOR_SET` env, optional until then — the entrypoint writes `yellowbackattestorset=`), Secret `<release>-yellowback-attestor` (`setid`, `address`, `wif`), `kubectl rollout restart statefulset`, wait for `yed_getinfo` (JSON-RPC via the Service), `kubectl rollout restart deployment/lightwalletd` (it probes `yed_getinfo` once at startup). Idempotent: a recorded set is reused, an armed node is left alone. Result: `yed_getinfo` rpcversion 6, `upgrade.status active`, `attestorSetId 6669fc9c…`, `attest.status UNARMED` (no attestors registered — a persona for K2+); lightwalletd logs `Yellowback service started`; smoke green with `GetYellowbackInfo`, `GetVaultInfo`, `GetChainInfo`, `ListSets` required and `GetAddressTokens` answering (empty stream for the coinbase address). No node change, no node ask |
| **K0c** YED for real on kind | attestors, prices and pool quotes against the kind node, host-run with the devnet's own agents; the web wallet mints, redeems and claims | `yed_getinfo` ARMED with a price and mintable classes; a real mint, send and redeem from the browser | **done 2026-10-10 on the live kind cluster.** §1.2 has the arming sequence. Chart: the arming Job (`arm-yellowback-r2`, the name carries a revision because a Job's template is immutable; the label `component=arm-yellowback` is what scripts look up) also records a payout address; the StatefulSet appends `-yellowbackpayoutaddress` from the ConfigMap through `lookup`; `kind-up.sh` and `kind-reset-chain.sh` run the one more `helm upgrade` that needs. `make kind-personas-up|down|status` → `scripts/kind-personas.py` (workspace venv, stdlib only): the pool (helm upgrade, announced and retried while locked), `yellowback-quote` + the windows, 3 × `yed_registerattestor`, 3 × `yellowback-attest attest` + 1 `subscribe` on the `dir` bus, the price walk. Evidence: `yed_getinfo` attest `ARMED` (3 seated, poolFresh 3), pool payout `sma26HTGU…`, quote `quote`; `yed_getprice` pMint 50 000 000 µUSD, xMint the same, quote tags 8/24/52 of 8/24/64; `yed_getstats` minting allowed, halts `[]`, classes A, B, C; `yed_estimatecollateral 10000 48` → 6 YEC, class A, bundle seqs 0, 1, 2. The web wallet (`yew/web/scripts/test-web-smoke.sh --kind --mint https://localhost/`, K4's bundle through the gateway; yew `up/web` f868f61), green at 2026-10-10 06:4x UTC, 81 s: Mint $100.00 for 48 blocks → estimate `Collateral to lock 5.82036000 YEC · class A · Enforcement fee 0.50000000 YEC · Total 6.44558000 YEC` (the walk had the price at ~$51.5) → the carrier funded by the slider → Sync → `Slide to mint` → `MAIN_SENT` → Sync → `Minted $100.00` (mint txid `c3eedf6e1ee856bd…afc2d30c`, height 2286), the vault row `$100.00 · 5.82036000 YEC / class A · ACTIVE · redeemable now` on the Yellowback screen, 1 YED to the node's `yr…` address (verdict ok, Sent) and 1 YED back from the node (`452041be…ca99ea`), the early redeem `YED burned $100.00 · Collateral returned 5.02953200 YEC · Enforcement fee 0.79101800 YEC (0.29101800 early-redeem)` → `Vault redeemed` → Sync → `No open vault · 1 closed`; after it `$0.00 · 1.89990000 YEC private · 7.68378200 YEC public`. Two things learned for the wallet: the core advances a two-step row only from a sync (the smoke presses Sync before every "Check the carrier"), and `ListClaimable` showed an earlier run's `ACTIVE` vault with `claimable: false` (owner `yrV7Sty…`, 289 % collateralised) as a Claimable row with `you keep about 0 YEC · clause ''` — lightwalletd streams every `yed_listclaimable` row and the screen does not filter on `claimable`; a yew/lightwalletd item, noted, not fixed here. Found on the way: the demo-kit agent's `helm upgrade` from a tree without the lookup reverted the pool flag mid-run (revision 17) — hence the resumable `up`. Still host-run: every agent and the walk (in-cluster personas: `images/personas/`, a skeleton; §2 K0c-ii) |
| **K1** measurement | `load/run.sh`: ghz per method through the gateway, node RPC queue depth watched | the ceiling per method recorded in §4 | **first run 2026-10-09** (§4); `load/run.sh` fixed on the way (one `--proto` per service, `--skipTLS` for the self-signed cert, the kind coinbase address by default, `SPREAD_PEERS=1`). The limiters, not the node, are the ceiling from one IP — see §4 and A-3 |
| **K2** EKS | `infra/eks` applied; add-ons; ECR push; `values-eks.yaml` on a real cluster; RDS for yindex | smoke green on the public host; YEW's devnet suites pointed at it | **written and validated offline 2026-10-09, not applied** (no AWS credentials in the workspace): `infra/eks` now one apply — VPC, EKS, IRSA (+ cert-manager), ECR, gp3, RDS Postgres 17 `db.t4g.small` (`rds.tf`), Secrets Manager `ycash/lite/ycashd-rpc` + `yindex-postgres` generated by terraform (`secrets.tf`), the seven add-ons as `helm_release` (`addons.tf`) with ClusterIssuer `letsencrypt-prod` (Route53 DNS-01) and ClusterSecretStore in the local chart `charts/cluster-config`; `terraform validate` + `fmt -check` green, the EKS render through kubeconform with the CRD schemas green (25 resources). Chart: `gateway.service.externalDns` (the hostname annotation from `gateway.host`), `gateway.trustForwardedHeaders: false` (A-3: the merged K3 design, proven on kind; `numTrustedHops` was dropped because it makes Envoy trust a client XFF), `values-eks.yaml` with the plaintext listener and regtest off and the images set by `make eks-deploy`. `make eks-up / eks-push / eks-deploy / eks-smoke / eks-down / eks-validate`, CI job `eks`, `docs/eks-runbook.md` (order, verification, cost ≈ $625–645/month, rollback, decisions K2-1..K2-4 for the owner: DNS-01 vs HTTP-01, RDS vs in-cluster, single vs multi-AZ, which chain). Still to do with credentials: the apply, the push, the deploy, DNS, the smoke on the public host, YEW's suites, the §4 EKS re-run |
| **K3** yindex live | ingester + server (written) routed by the gateway; reorg test on kind; parity test against lightwalletd's node-proxied answers | `GetAddressUtxos`/`GetTaddressTxids`/`GetTaddressBalance` from yindex equal lightwalletd's for every address the regtest suite touches, across a reorg | code written 2026-10-08; first parity check green the same day for the coinbase address (200 UTXOs, 178250000000 zat, 200 txids). **done 2026-10-10** (`up/k3`): `scripts/parity.sh` (`make kind-parity`) walks every block from height 1 (`getblock <h> 2`), collects every scriptPubKey address and compares, per address, the UTXO rows (sorted, byte-for-byte as JSON), the balance and the `GetTaddressTxids` stream (height + raw bytes) between yindex through the gateway and the lightwalletd Service port-forwarded; a mismatch is re-tried three times (the chain moves every 5 s, the ingester polls every 2 s) and a failed call never matches. Before the reorg: 336 addresses (the kind miner takes a new address per block), 1015 UTXO rows, 1068 txids at tip 532, 0 mismatches, 42 s. Reorg: `invalidateblock` of height 591 (tip 594) at 00:11:18Z; the ingester logged `reorg at 591 (ours 05a3e1df…, node 09520095…), rewinding 594 -> 590` at 00:11:24Z and re-applied 591… on the new branch; after it 403 addresses, 1153 UTXO rows, 1206 txids at tip 601, 0 mismatches, and the four orphaned coinbase addresses answer 0 UTXOs / 0 txids / balance 0 from yindex. `internal/ingest` now takes `Node`/`Index` interfaces and `ingest_test.go` covers the 3-deep reorg, the shorter-node case (invalidateblock before the miner catches up: no spurious error, the fork point found below the node's tip) and a block whose parent is not our tip, with a fake RPC — no cluster needed (`go test ./...`). Found on the way: the node readiness probe counted the invalidated branch (`getblockchaininfo.headers`) as the best tip, so the node left the Service for 2.5 min (00:11:24Z–00:13:50Z) and the in-cluster miner, which reaches it through the Service, could not mine it out — a deadlock broken by mining three blocks through the pod. `ready.sh` now takes the best non-invalid `getchaintips` height; **not yet applied** to the kind cluster (a ConfigMap change, a helm upgrade the coordinator schedules; no pod restart) |
| **K3b** verdict cache | a tip-hash-keyed cache for `yed_*` reads inside `lightwalletd-dd`'s `CallYed` (its repo; small, reviewable) | per-block, not per-user, node load for `GetAddressTokens` | **done 2026-10-09** in lightwalletd-dd `upgrade/vault` (`cb03bf3`, `f0746e4`): in-process LRU per (method, canonical args, ingestor tip hash), `--yellowback-cache-entries` 10000 / `--yellowback-cache-bytes` 64 MiB (`LWD_YELLOWBACK_CACHE_ENTRIES`, 0 = off), counter `lightwalletd_yellowback_cache_requests_total{method,result}`; cacheable table with reasons in its `docs/yellowback.md` (validate/buildbundle/getselection/getattestations/listattestors stay uncached: mempool or attestation-pool state). Measured beside kind: `GetAddressTokens` 1.8k → 31k rps, p50 25 → 1 ms, node `yed_listtokens` 6000 → 50 per 6000 requests; `GetPrice` unchanged (already served per tip). Not Redis: no vendored Go client (D-L-6); the per-tip key makes a shared store optional, so the chart's Redis is unused by lightwalletd until a vendoring decision. Follow-up: single-flight for concurrent misses on a fresh tip. Rebuild the lightwalletd image to take it on kind |
| **K4** web bundle | `yew/web` dist served by the gateway with the CSP/COOP/COEP headers | the web wallet syncs and sends on kind | after `yew/web` W1. **Precondition met 2026-10-09:** the browser core (yew-web-core, W0.5) opens, syncs, receives a private payment and restores from genesis against this cluster's gRPC-web listener (`:9067`, CORS via `gateway.plaintextGrpcCors`), after the chain gained the seven regtest upgrades at height 1 (`146c5a8`). **done 2026-10-10 on the live kind cluster** (one `helm upgrade`; the chart head's render equalled the live manifest, so only the web Deployment, its Service and the HTTPRoute were created): `make image-web YEW=<yew tree>` builds `images/web` with the bundle as a named build context (`--build-context dist=$(YEW)/web/dist`; the old `docker build` with `yew/web` as the context could not see `nginx.conf`), `nginx.conf` is an envsubst template — CSP `connect-src 'self' https://download.z.cash $CSP_CONNECT_SRC_EXTRA` (the proving files' standard source; chart `web.env`, kind sets `http://127.0.0.1:8766` for the smoke's loopback helper, production empty), the `.wasm` location's own `add_header` removed (it dropped the inherited COOP/COEP/CSP on the wasm response; `expires` on `/assets/` instead). `curl -I https://localhost/`: COOP `same-origin`, COEP `require-corp`, the CSP, nosniff, no-referrer; assets immutable for a year. **The web wallet syncs and sends on kind through the gateway:** yew's `web/scripts/test-web-smoke.sh --kind https://localhost/` (headless Chrome, the real core, the API on the same origin — the shell defaults its server to the page's origin) walks onboarding → 2 YEC public funding → a 0.5 YEC public send → 1.5 YEC private funding → history → the proving files → a 0.4 YEC shield (5.2 s) → a 0.3 YEC z→z with a memo (21.7 s) → reload/unlock with the balances persisted → Yellowback (mint halted: NO_PRICE, no vault, nothing claimable) in 51 s; the same walk on `vite preview` + `:9067` in 49 s (yew plan §5 W2). The plain listener stays for the dev loop; `GRPCRoute` method matches take precedence over the HTTPRoute's `/` prefix on the https listener, so gRPC-web and the bundle share the origin |

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
| `GetLatestBlock` | 15,012 (p50 2 ms, p95 4 ms, p99 5 ms) | no queue warning (`rpcworkqueue` 32, `rpcthreads` 8); lightwalletd answers from its block cache | 2026-10-09, kind arm64, ycashd 6.22.0-rc1 (`b3ae528`), lightwalletd-dd `c8346c3` |
| `GetAddressUtxos` (yindex) | 5,676 (p50 7 ms, p95 12 ms, p99 15 ms) | none: yindex answers from Postgres, the node is not called | same |
| `GetTaddressBalance` (yindex) | 5,066 (p50 7 ms, p95 18 ms, p99 25 ms) | none (yindex) | same |
| `GetPrice` | 10,365 (p50 3 ms, p95 5 ms, p99 6 ms) | no queue warning | same, `SPREAD_PEERS=1` |
| `GetAddressTokens` | 1,340 (p50 31 ms, p95 60 ms, p99 78 ms) | no queue warning; every call is a `yed_listtokens` on the node — the K3b cache target | same, `SPREAD_PEERS=1` |
| `GetVaultInfo` | 8,183 (p50 4 ms, p95 7 ms, p99 8 ms) | no queue warning (`vault_getinfo`) | same, `SPREAD_PEERS=1` |

How measured: ghz, 2,000 requests at concurrency 50 from the laptop, TLS through the gateway
(`load/run.sh localhost:443`). With the kind defaults a single client IP never reaches the node:
the gateway's per-IP limit (500/s) answers `local_rate_limited` for ~70 % of the calls, and
lightwalletd-dd's per-peer Yellowback bucket (20 calls, +1/s, light calls cost 0.2) answers
`ResourceExhausted` for ~90 % of the Yellowback calls. The rows above were taken with
`gateway.rateLimit.enabled=false` (restored afterwards) and, for the Yellowback methods, a
distinct `x-real-ip` per request (`SPREAD_PEERS=1`), which measures the node and not the bucket.
The node's RPC work queue (depth 32, 8 threads) logged no overflow at any of these rates; the
one regtest node is far from its ceiling for the stock reads, and `GetAddressTokens` at ~1.3 k
calls/s is the only method whose cost is a node walk per call. Re-run on EKS (K2) with the
mainnet image and a real tip.


## 5. Node asks (recorded, not scheduled)

- A-1: `yed_listtokens` returning the tip hash it answered at, so the K3b cache key is exact
  rather than read in a second call.
- A-2: `getblock` verbosity 2 includes `valueZat`; confirm on both lines (`valueSat` fallback in
  `rpc/client.go`).
- A-3 (lightwalletd-dd + gateway, not the node; found by K1 on 2026-10-09; **closed at the gateway
  2026-10-10**, `up/k3`): with the gateway in `--trusted-proxy-cidr`, lightwalletd-dd's Yellowback
  limiter believes `x-real-ip` and the *first* `x-forwarded-for` entry — and Envoy forwarded a
  client-supplied `x-real-ip` untouched and *appended* to a client-supplied `x-forwarded-for`. A
  client that set `x-real-ip: <anything>` per request got a fresh bucket per request: measured
  before the fix on kind, 60 `GetAddressTokens` (a heavy call) with a spoofed `x-real-ip` each →
  60 answered / 0 limited, against 40 / 20 unspoofed (20 per bucket × the two lightwalletd
  replicas). Fix: the chart's `ClientTrafficPolicy` drops `x-real-ip` and `x-forwarded-for` as
  *early* request headers (`headers.earlyRequestHeaders.remove`, Envoy's
  `early_header_mutation`, which runs before the connection manager appends the peer address to
  XFF; `use_remote_address` stays true), so the only `x-forwarded-for` lightwalletd sees is the
  one Envoy writes from the connection. Value `gateway.trustForwardedHeaders` (false) keeps the
  door for a deployment behind another L7 proxy. Applied to kind in one `helm upgrade` at
  00:07:28Z (the policy reconfigures Envoy in place: no Envoy, lightwalletd or node restart).
  After it: spoofed `x-real-ip` 41 / 19, spoofed `x-forwarded-for` 40 / 20 — the unspoofed
  figures. `scripts/smoke.sh` ends with this burst and fails when nothing is limited;
  `load/run.sh SPREAD_PEERS=1` no longer spreads (to measure the node's Yellowback ceiling, raise
  the limiter or run ghz from several hosts). **Ask for lightwalletd-dd** (its repo, not edited
  here): `peerKey` still takes `x-real-ip` and the *leftmost* `x-forwarded-for` entry from a
  trusted proxy. With this gateway that is correct, but defence in depth and other front ends
  want the entry `numTrustedHops` from the *right* (the rightmost is what the trusted proxy
  itself appended) and `x-real-ip` only when explicitly configured; on kind, note, every host
  client arrives from the one NAT address, so the whole laptop is one peer after the fix.
- K0b needed no node change: the entrypoint's `YCASHD_YELLOWBACK_ATTESTOR_SET` (`contrib/docker/ycashd`,
  K0a) and the `set_*` / `yed_getinfo` RPCs were enough.

## 6. Risks

- Envoy Gateway's gRPC-web is applied as an `EnvoyPatchPolicy` (its native option is still
  tracked upstream); the patch targets the listener name and must be re-checked on each EG upgrade.
- Two nodes briefly disagree at the tip during a reorg: the readiness probe's lag check hides a
  node a block behind, and the clients rewind 10 blocks. K3's reorg test covers yindex. The lag
  check must never count an invalid branch (K3 found it did: a longer invalidated branch made
  the node unready and, on kind, unminable — fixed in `ready.sh`, pending apply).
- Building the node image from source is 1–2 h per line per architecture; a GitHub release
  tarball (Dockerfile.release in the node repo, to add once 6.22.0 ships) makes it minutes.
