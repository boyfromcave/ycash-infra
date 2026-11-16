# images/faucet — the faucet (kind demo and testnets)

## In plain words

A faucet is a small web page that gives out free coins of a practice network, so that people can try
a wallet without buying anything. This image is that page and the program behind it. It runs in two
ways: on a laptop's demo chain (where it also mines blocks on request), and on the public Ycash
testnets, where it only ever sends a fixed, small amount of worthless testnet YEC, limits how often
any one visitor or address can ask, and stops by itself if it is ever pointed at anything but a
testnet. It never holds the wallet's secret words itself; the testnet node that pays does.

## Two modes (`FAUCET_MODE`)

| | `regtest` (default) | `testnet` |
|---|---|---|
| Where | `charts/ycash-lightwallet` `regtest.faucet` (kind demo, `docs/try-it.md`), at `/faucet/` | `charts/ycash-testnet` `faucet` (plan §6.2), on its own host per network; the x402 host (`infra/testnet-seeds`, a network's `x402`) at `/faucet/` |
| Pays from | the in-cluster miner's wallet | the first Sapling address of its own wallet node (`<release>-faucet-node`), restored from a recovery phrase in a Secret (`-mnemonicfile`) |
| Routes | page, `/send`, `/fund`, `/fund_t`, `/address`, `/mine`, `/reorg`, `/info`, `/params/`, `/metrics` | page, `/info`, `/challenge`, `/send`, `/metrics` (inside the cluster only), `/params/` only with `PARAMS_ENABLED=1` |
| Amount | chosen by the caller (up to 1,000 YEC) | fixed (`AMOUNT_ZAT`, 1 YEC by default) |
| Limits | one action per `RATE_SECONDS` | per client IP (`PER_IP_LIMIT` per `PER_IP_WINDOW`; IPv6 per /64, from the gateway's `X-Forwarded-For` entry, `TRUSTED_PROXY_HOPS`), per recipient (`PER_ADDR_*`), `DAILY_CAP_ZAT` in any 24 h, one payment at a time and `RATE_SECONDS` apart, an optional proof-of-work challenge (`POW_BITS` leading zero bits of SHA-256, solved by the page) |
| Safety | regtest only | pays nothing unless the node's `getblockchaininfo.chain` is `test` and its `testnetprofile` is `FAUCET_PROFILE`; the node validates every address (`validateaddress`, `z_validateaddress`); node errors stay in the log |

**The sweep (testnet mode, `SWEEP_FROM`).** On the x402 host the paid API's `payTo` is a
transparent address of the faucet's own wallet, so what agents pay comes back to the faucet. Every
`SWEEP_SECONDS` (600) the faucet checks those addresses (`SWEEP_FROM`, comma separated) and merges
their coins into the Sapling address it pays from (`z_mergetoaddress`, the node's fee,
`AllowRevealedSenders`: the senders are the wallet's own addresses), never while a payment is in
flight; `faucet_swept_zat_total` counts it. It takes only coins at least `SWEEP_MIN_CONF` (2) deep,
so it never spends a payment the x402 facilitator may still be observing with `gettxout`, and never a
coin below `SWEEP_DUST_ZAT` (5,000 zat, the ZIP 317 marginal fee: `payTo` is public and anyone can
send it dust), at most 50 per merge, the largest first; the others are locked (`lockunspent`) for the
merge and unlocked after it. When what it may take is below `SWEEP_MIN_ZAT` (0.01 YEC), or would not
cover the merge's fee (5,000 zat per input and per Sapling output), the cycle does nothing and logs
nothing. It sweeps nothing on any chain but the testnet profile it is set to. Empty `SWEEP_FROM`
(the default) = off.

The testnet mode pays testnet YEC only, never YED (users mint YED themselves). Its limits live in
memory, so the chart runs one replica; a restart forgets the per-IP and per-address windows, which the
daily cap still bounds. Its metrics (`faucet_balance_zat`, `faucet_paid_zat_total`,
`faucet_paid_zat_24h`, `faucet_chain_ok`) feed the chart's alerts.

## Files

| File | What |
|---|---|
| `faucet.py` | the server, both modes (Python standard library only) |
| `index.html`, `app.js` | the regtest page |
| `testnet.html`, `testnet.js` | the testnet page (solves the challenge with WebCrypto) |
| `fetch-params.py` | the init container that fills the Sapling proving files' volume (SHA-256 checked) |
| `tests/test_faucet.py` | offline tests against a stand-in node: `make services-test` |

Build: `make image-faucet` (`ycash/faucet:local`). Published by `.github/workflows/faucet-image.yml`
(by hand, from `upgrade/vault`, after the offline tests) as `ghcr.io/<owner>/ycash-faucet`, with build
provenance; the x402 host's `x402.faucet_image` and the testnet chart's `images.faucet` take it by digest.
