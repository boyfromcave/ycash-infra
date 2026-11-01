# infra/vast-miners: the testnet GPU miner fleet on Vast.ai

## In plain words

The Ycash testnets need blocks, and blocks need graphics cards: Ycash's proof of work (Equihash
192,7) is far too slow on ordinary processors. The big clouds (AWS, Google Cloud, Azure) forbid or
restrict cryptocurrency mining in their terms, so the testnet's cards are rented on **Vast.ai**, a
marketplace where people rent out their own GPUs by the hour and where mining is allowed (paid with
credit bought with cryptocurrency, per Vast's terms).

A small **fleet file** says, per testnet: how many miners, which cards, the most to pay per hour, and
which pools to mine into. [`scripts/vast-fleet.py`](../../scripts/vast-fleet.py) compares that with
what is actually rented and fixes the difference: it rents the cheapest matching card for a missing
miner, replaces one that died, and gives back the ones no longer wanted. Each rented machine runs
the [miner image](../../images/miner/README.md), which downloads the mining program (lolMiner by
default) from its official release at start and checks its pinned fingerprint, and mines into a [yolo](https://github.com/boyfromcave/yolo)
pool. The pools and the testnet nodes stay on our own servers; only the mining is rented.

Nothing here holds a real value: the actual fleet file (pool addresses, the image digest) and the
Vast API key live in the private deployment repository and its GitHub environment, which runs this
script from a pinned commit.

## How it fits together

```
private deployment repo                         this repo (public, pinned by commit)
  fleet.json  (pools, digest, sizes)  ──────►  scripts/vast-fleet.py  ──REST──►  Vast.ai
  workflow: status / reconcile / up /            images/miner (ghcr)               │ rents 1-GPU machines
            down / burst, every 30 min                                               ▼
  secret VAST_API_KEY (environment)              miner ──stratum──► yolo pool ──RPC──► ycashd (testnet seed)
```

- A miner is **ours** only if its Vast label is `ycash-<network>-<n>` (a burst miner:
  `ycash-<network>-<n>.until-<YYYYMMDDTHHMMZ>`). Anything else on the account is counted and never
  touched, even by `down`.
- Miners of one network are spread over its pools round-robin: miner `n` mines into pool
  `n mod (number of pools)`, so two miners and two pools put one on each.
- A miner is rented as a **one-GPU** machine, from the cheapest verified offer for one of the listed
  cards at or under `max_dph` (dollars per hour, storage included) with at least `min_reliability`.
  The script checks card, count, reliability and price itself, whatever the search returns.
- **Dead** means: exited, stopped, offline, or still starting after `max_start_minutes` (30). A dead
  miner is destroyed and its slot rented again in the same run. So is a running miner whose miner
  or pool no longer matches the file (when Vast reports its environment).
- **Which miner:** `lolminer` unless the network's `miner` says otherwise; a list is spread over the
  slots like the pools (`["lolminer", "miniz"]` puts miniZ on slot 1). miniZ is refused unless the
  fleet pins `miniz_url` and `miniz_sha256` (public values), which reach the container as
  `MINIZ_URL` / `MINIZ_SHA256`.
- **Hard limits** in the script, whatever the file says: 8 miners per network, 16 in all, $1/h per
  miner, bursts of at most 168 hours.

## The fleet file

[`fleet.example.json`](fleet.example.json) (placeholders only), format `ycash-vast-fleet/1`:

| Field | Meaning |
|---|---|
| `image` | the miner image **by digest** (`ghcr.io/<owner>/ycash-miner@sha256:…`, from `miner-image.yml`); per network `image` overrides it |
| `disk_gb` | disk per machine (default 8) |
| `miniz_url`, `miniz_sha256` | miniZ's official https download and its SHA-256; both empty (miniZ off) until the owner has read miniZ's Terms and confirmed its 192,7 flags (`images/miner/README.md`) |
| `max_start_minutes` | how long a machine may stay "loading" before it counts as dead (default 30) |
| `networks.<name>.count` | how many miners always on (0 = none, only bursts) |
| `gpu_names` | the cards accepted, as Vast names them (`"RTX 3060"`, `"RTX 3070"`, `"RTX A4000"`, …) |
| `max_dph` | the most to pay per miner per hour |
| `min_reliability` | Vast's host reliability score, 0 to 1 |
| `rental` | `on-demand` (keeps running) or `interruptible` (cheaper, can be outbid and stopped; bids 10 % over the offer's minimum, never over `max_dph`) |
| `pools` | the stratum pools, `host:port` |
| `worker_prefix` | miner `n` is worker `<prefix>-<n>` |
| `payout` | empty (the pool runs with `--payout`) or a transparent address (the pool pays usernames) |
| `extra_args` | extra miner options (no pool, user, password or algorithm options) |
| `miner` | `lolminer` (default) or `miniz`, or a list of them spread over the slots; passed as `MINER` |

The script **refuses** a file with a field named like a secret (`key`, `token`, `pass…`, `secret`,
`auth`, …) or a value that looks like one (a long hex or token string, a private key block,
`user:password@` in a URL): a miner may carry only a pool address, a worker name and a payout
address. It **will not start** a network whose pool address is a placeholder (a host under
`.example` or `.invalid`) or whose image digest is the all-zero placeholder.

## Actions

```bash
export VAST_API_KEY=…            # from the environment only; never an argument, never printed
python3 -I scripts/vast-fleet.py --fleet fleet.json validate          # offline
python3 -I scripts/vast-fleet.py --fleet fleet.json status
python3 -I scripts/vast-fleet.py --fleet fleet.json --dry-run reconcile
python3 -I scripts/vast-fleet.py --fleet fleet.json reconcile [--network slow]
python3 -I scripts/vast-fleet.py --fleet fleet.json burst legacy 1 --hours 48
python3 -I scripts/vast-fleet.py --fleet fleet.json expire            # only ends bursts whose time is up
python3 -I scripts/vast-fleet.py --fleet fleet.json down [--network legacy]
```

- `reconcile` is idempotent: run it as often as you like; a second run changes nothing.
- `burst NET N --hours H` runs `N` miners on `NET` until now + `H`. Slots above the file's `count`
  are labelled with their end time; `reconcile` keeps them until then and destroys them after, and
  `expire` does only that (it never rents). A later burst on the same network sets a new end time
  (relabels, no new rental) and gives back slots above its `N`.
- `--dry-run` reads the account and the offers and prints what it would do, changing nothing.
- In GitHub Actions the key, every instance id and every host address are masked (`::add-mask::`)
  before anything is printed; instances are shown by label only. API errors are cut short and the
  key and IP addresses are removed from them.
- Exit status 1 when anything could not be done (no offer under the cap, a placeholder, no credit);
  the rest of the run still happens.

The REST calls are the ones the `vastai` CLI 1.10.0 makes (`GET /api/v1/instances/`,
`POST /api/v0/bundles/`, `PUT /api/v0/asks/<offer>/`, `PUT|DELETE /api/v0/instances/<id>/`), with
the standard library only; the CLI itself is not needed. A new instance runs the image's own
entrypoint (`runtype: args`) with the pool, worker and payout as environment variables.

## Hash rate and cost (testnet floors)

| Network | Minimum difficulty needs | Suggested | Roughly |
|---|---|---|---|
| testnet-yb-fast | about 0.43 Sol/s for 75 s blocks (testnet PoW limit: 32 solutions per block) | 1 × the cheapest card (RTX 3060 class) | $45–60 a month |
| testnet-yb-slow | about 109 Sol/s for 75 s blocks (mainnet's PoW limit after the shadow fork: 8,192 solutions per block); one RTX 3070-class card does about 45–60 Sol/s, so about 150 s blocks | 2 × RTX 3070 class, one per pool | $120–190 a month |
| testnet-legacy | as slow | 0 by default; bursts for campaigns | about $25 a month when used |

Prices on Vast change daily; `status` prints the fleet's current $/h. A later cost option for fast:
CPU mining with the node's own open-source 192,7 solver on a cheap Vast machine (not on AWS, whose
terms prohibit mining); not built.

## Tests

`make miners-test`: `scripts/tests/test_vast_fleet.py` runs every action against
[`scripts/tests/fake_vast.py`](../../scripts/tests/fake_vast.py), a local stand-in for the Vast API
(nothing is rented): it starts the right number at the cheapest offer under the cap, ignores
offers over the cap or for other cards, replaces a dead or stuck miner, destroys extras and
networks no longer in the file, never touches unlabelled instances, bursts and expires, refuses a
fleet file with a secret-looking field, validates `miner` (miniZ only with its pins), replaces a
miner whose miner or pool changed, and never prints the key (in and outside GitHub Actions).
