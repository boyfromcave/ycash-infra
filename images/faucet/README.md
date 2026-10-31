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
| Where | `charts/ycash-lightwallet` `regtest.faucet` (kind demo, `docs/try-it.md`), at `/faucet/` | `charts/ycash-testnet` `faucet` (plan §6.2), on its own host per network |
| Pays from | the in-cluster miner's wallet | the first Sapling address of its own wallet node (`<release>-faucet-node`), restored from a recovery phrase in a Secret (`-mnemonicfile`) |
| Routes | page, `/send`, `/fund`, `/fund_t`, `/address`, `/mine`, `/reorg`, `/info`, `/params/`, `/metrics` | page, `/info`, `/challenge`, `/send`, `/metrics` (inside the cluster only), `/params/` only with `PARAMS_ENABLED=1` |
| Amount | chosen by the caller (up to 1,000 YEC) | fixed (`AMOUNT_ZAT`, 1 YEC by default) |
| Limits | one action per `RATE_SECONDS` | per client IP (`PER_IP_LIMIT` per `PER_IP_WINDOW`; IPv6 per /64, from the gateway's `X-Forwarded-For` entry, `TRUSTED_PROXY_HOPS`), per recipient (`PER_ADDR_*`), `DAILY_CAP_ZAT` in any 24 h, one payment at a time and `RATE_SECONDS` apart, an optional proof-of-work challenge (`POW_BITS` leading zero bits of SHA-256, solved by the page) |
| Safety | regtest only | pays nothing unless the node's `getblockchaininfo.chain` is `test` and its `testnetprofile` is `FAUCET_PROFILE`; the node validates every address (`validateaddress`, `z_validateaddress`); node errors stay in the log |

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

Build: `make image-faucet` (`ycash/faucet:local`). No published image yet: the testnet chart takes
`images.faucet` by digest once one is (README "The services" in `charts/ycash-testnet`).
