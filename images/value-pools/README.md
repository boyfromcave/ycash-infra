# images/value-pools — the value-pools page of an explorer host

## In plain words

A small web page that says how much YEC sits in each pool of the chain: the two shielded pools
(Sapling, Sprout), ordinary transparent addresses, post-quantum addresses by signature scheme
(Falcon, SLH-DSA) and vaults; now, and over time as charts. The figures come from the node itself,
which keeps them in its value-pool index from release 6.22.0-beta3 on (koganyd beta3 serves the same
fields), so every node of that release reports the same numbers for the same block. The page shows
totals for the whole chain only: nothing about any address or transaction.

It is our own component. It runs beside the Inzyght explorer and is served by the same proxy under
`/pools/`, but it is not part of Inzyght, adds no page to it and uses none of its code or styles
(Inzyght has no licence, `images/inzyght/README.md`).

## What runs

One container, one process (`pools.py`, Python's standard library only), about 25 MiB of memory:

- a **sampler** thread, the only thing that talks to the node. It polls `getblockchaininfo` every
  `POLL_SECONDS` (5), follows the tip, and fills the history file;
- an **HTTP server** on 8080 that answers from memory: the page and the JSON API below.

The node is asked three read-only calls and nothing else: `getblockchaininfo`, `getblockhash`,
`getblock <height or hash> 1`. The service refuses to send any other method. It holds the node's RPC
credential (the one Inzyght uses) in its environment and no other secret, and it needs no route to
the internet: the page is one file with its style and script inline, no font, library or image
loaded from anywhere, served with a Content-Security-Policy that admits exactly those two inline
blocks by their sha256.

## The page

`GET /pools/`: one screen, readable on a phone, light or dark by the reader's system setting.

- **The totals at the tip**, as a table: Sapling, Sprout, Transparent (ECC), Post-quantum Falcon
  (FN-DSA-512), Post-quantum SLH-DSA (SLH-DSA-SHA2-128s), Vault, and the total supply, each in YEC
  with its share of the supply; the tip's height (a link to the explorer's block page), its time,
  and "updated n seconds ago". Vault intents, post-quantum channels and Orchard get a row only when
  they hold something, so the rows always add up to the total. A line under the table says whether
  the sums held at that block.
- **Three charts over block height**, each with its own scale: Transparent (ECC), Sprout and
  Sapling, stacked; the two post-quantum pools as lines (they are thousands of times smaller);
  YEC locked in vaults. Range buttons: last day, last 1,000 blocks, since the Vault activation,
  all. Pointing at or tapping a chart, or the arrow keys, shows every pool's value at that block,
  with a link to the block. The horizontal axis is block height, not time: this testnet inherits
  510,247 blocks of old history, and a time axis would be a line with a gap of years.
- **Accessibility:** the numbers are a real table; the charts' figures are also available as a
  table under them; each pool has a colour and a name beside every value, and the two lines of the
  post-quantum chart differ in dash as well as colour.
- **A note** on what the numbers are, what "monitored" means, and what is not shown.

`?theme=dark` or `?theme=light` overrides the system setting (for a screenshot).

## The API

All `GET`, JSON, under `/pools/api/v1/`. Amounts are **integers in zatoshis** (1 YEC = 100,000,000
zatoshis); the whole supply stays below 2^53, so they are exact in every JSON reader. `current` also
gives each amount as a decimal string in YEC. `null` means the node did not report that figure at
that block (not monitored).

| Route | Answer |
|---|---|
| `current` | The tip: `height`, `hash`, `time`, `updated` (when the node last answered), `ageSeconds`, `monitored`; `pools` (the disjoint pools: `sapling`, `sprout`, `transparent_ecc`, `pq_falcon`, `pq_slh_dsa`, `pq_channel`, `vault`, `vault_intent`, `orchard`, `other`), each `{id, label, zat, yec, sharePercent, monitored}`; `aggregates` (`transparent`, `transparent_pq`, `vault_yed`, `supply`); `checks`; `upgrades` (the Ycash and Vault activation heights); `links.block`; `history` (the sampler's tiers and what is still to fetch) |
| `series?from=&to=&max=` | Totals over height: `heights`, `times`, `monitored`, and `pools.<id>` (one array per pool and aggregate), at most `max` points (default 300, at most `MAX_POINTS` 600) on a grid of `step` blocks (1, 2, 5, 10, 20, 50, ...), always including `from` and `to`. `to` defaults to the tip. Instead of `from`: `last=<blocks>`, or `seconds=<s>` (from the first sampled block not older than that before the tip's time). `complete` is false when some grid points could not be given |
| `deltas?count=` | What each of the last `count` blocks (default 100, at most 500) added to or took from each pool: `heights`, `times`, `deltas.<id>` |
| `status` | The sampler: stored samples, blocks still to fetch, RPC calls made, how long the first history took, `deltaMismatches`, `reorgDrops`, the last error |

`/pools/healthz` answers `ok` while the process serves HTTP (the container's health check).

**The sums that must hold** (`current.checks`, each `{holds, sumZat, expectedZat, parts, total}`):

- `transparent`: `transparent_ecc + transparent_pq + pq_channel + vault + vault_intent = transparent`
- `postQuantum`: `pq_slh_dsa + pq_falcon = transparent_pq`
- `supply`: `transparent + sprout + sapling + orchard + other = supply` (the node's `chainSupply`)

`holds` is `null` when the node did not report a part. The sampler also compares every block's own
`valueDelta` with the difference of the two totals it stored; `status.deltaMismatches` counts
disagreements (0 on a healthy node).

The field definitions are the node's (workspace `docs/plans/beta3/value-pools.md`): `vault` counts
vault outputs and `vault_intent` YEC already released and waiting out its delay; `vault_yed` is the
part of both under the YED module's tag; YEC under YED tokens is ordinary Falcon value and is
counted in `pq_falcon`.

## History: what is sampled, and what it costs the node

`getblock` gives the totals as of any height, so the service needs no index of its own, only
samples. Asking for every block of a 512,000-block chain would be 512,000 calls; it keeps three
tiers instead:

| Tier | Which blocks | On yb-fast today |
|---|---|---|
| recent | every block of the last `RECENT_BLOCKS` (2,000) | 2,000 |
| fine | every `FINE_STEP`-th (10th) block from `FINE_FROM` on | about 270 |
| coarse | every `COARSE_STEP`-th (1,000th) block of the whole chain | about 510 |

`FINE_FROM=auto` is the earlier of the Ycash and Vault activation heights that lies within
`FINE_MAX_SPAN` (200,000) blocks of the tip, rounded down to the coarse step (510,000 on yb-fast);
with neither, the tip minus 20,000. A block that leaves the recent window and is in no other tier is
dropped, so the store grows by one fine sample every 10 blocks.

**First start, measured** (a ycashd 6.22.0-beta3 on the fast testnet, tip 512,712, an arm64 laptop):
2,639 RPC calls in 143 seconds (the sampler waits `RPC_INTERVAL_MS`, 50 ms, between calls, so at
most 20 a second, one at a time), a 545 KB sample file, 22 MiB of memory. The node's part of that is
small: a `getblock` at verbosity 1 took about 3 ms there. The page is usable at once: the totals
appear with the first poll, the newest blocks are sampled first, and the page says how many blocks
are still to go. On a slower host raise `RPC_INTERVAL_MS`; at 200 ms the same history takes about
nine minutes.

**It resumes.** Every sample is appended to `DATA_DIR/samples.jsonl` as it is fetched; a restart
reads the file, checks it against the node and fetches only what is missing (a restart on a complete
file cost 5 calls).

**After that**, per new block: one `getblockchaininfo` every 5 seconds, and when the tip changes one
`getblock` for the new tip, one `getblockhash` to confirm the stored chain, and one `getblock` per
block in between.

**Reorganisations.** A block deeper than `REORG_MARGIN` (100) is final: the node refuses to
reorganise more than 99 blocks. On every tip change the service walks down from the new tip
comparing its stored block hashes with the node's until one agrees; whatever no longer is on the
chain is dropped and sampled again. That is one extra call when the chain only grew, and at most 100
after a reorganisation. At start the lowest and the highest final sample are compared with the node;
a difference (another network, a chain that was reset) wipes the file and the history is sampled
again.

**Visitors cannot make the node work.** `current` and `deltas` are answered from memory. `series`
is answered from the stored samples; only a range that no tier covers at the asked resolution (a
zoom into old history) makes it fetch blocks, and then at most `ONDEMAND_PER_REQUEST` (300) a
request, `ONDEMAND_PER_MINUTE` (600) a minute over all visitors, one such request at a time, final
blocks only, kept in memory (20,000 at most) for the next reader. When the budget is spent the answer
holds what is stored and says `complete: false`. The page's own four ranges are always covered by
the tiers. Each client address gets `API_PER_MINUTE` (120) API requests a minute (429 after that);
the address is the proxy's `X-Forwarded-For`, trusted only from `TRUSTED_PROXY`. At most 32 requests
are served at once.

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `RPC_URL` | `http://node:18832/` | the node's JSON-RPC |
| `RPC_USER`, `RPC_PASSWORD` | | its credential; or `RPC_COOKIE_FILE`, the node's `.cookie` (a local run) |
| `PORT`, `BIND` | `8080`, every address | where it listens |
| `DATA_DIR` | `/data` | `samples.jsonl` |
| `POOLS_PREFIX` | `/pools` | the path it is served under (it also answers without the prefix) |
| `EXPLORER_BLOCK_URL` | `/block/` | a block's page: the height is appended (Inzyght's `/block/<height or hash>`) |
| `NETWORK_NAME` | empty | shown in the heading, e.g. `Ycash fast testnet` |
| `TRUSTED_PROXY` | empty | the one peer address whose `X-Forwarded-For` names the client |
| `POLL_SECONDS` | `5` | how often the tip is polled |
| `RPC_INTERVAL_MS` | `50` | the pause between the sampler's calls |
| `RECENT_BLOCKS`, `FINE_STEP`, `FINE_FROM`, `FINE_MAX_SPAN`, `COARSE_STEP` | `2000`, `10`, `auto`, `200000`, `1000` | the tiers above |
| `REORG_MARGIN` | `100` | blocks deeper than this are final |
| `MAX_POINTS`, `ONDEMAND_PER_REQUEST`, `ONDEMAND_PER_MINUTE`, `API_PER_MINUTE` | `600`, `300`, `600`, `120` | the limits above |

## Build, run, test

```
make image-value-pools            # ycash/value-pools:local
make explorer-up EXPLORER_POOLS=1 # beside the local explorer stack (explorer/README.md "Value pools")
make services-test                # the offline tests, with the other services'

# without Docker, against a node on this machine (read-only):
RPC_URL=http://127.0.0.1:18842/ RPC_COOKIE_FILE=<datadir>/.cookie BIND=127.0.0.1 PORT=18977 \
  DATA_DIR=/tmp/pools python3 -I images/value-pools/pools.py     # then http://127.0.0.1:18977/pools/
```

Tests (`tests/test_pools.py`, offline): the parsing of both node lines' answers and of a node
without the split, the three sums, exact amounts; the sample file (restart, a torn line, rewriting);
the sampler against a stand-in chain (the tiers, resuming, new blocks, a reorganisation, a
reorganisation while stopped, another chain, a node that is away); the series and delta answers and
their limits; and the whole service over HTTP against a stub JSON-RPC node (the credential, the
allowed methods, the page's headers, that the page loads nothing external, the per-client limit).

Published by `.github/workflows/value-pools-image.yml` (started by hand, from `upgrade/vault`) as
`ghcr.io/<owner>/ycash-value-pools:<sha12>` with build provenance; an explorer host's
`explorer.pools.image` takes it by digest (`infra/testnet-seeds/README.md`, "The explorer": "Value
pools").
