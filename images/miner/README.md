# ycash-miner: the GPU miner for the Ycash testnets

`ghcr.io/<owner>/ycash-miner`, built by [`miner-image.yml`](../../.github/workflows/miner-image.yml)
from this directory, by hand, from `upgrade/vault`.

## In plain words

A Ycash network only moves forward when someone finds blocks, and finding a Ycash block means
solving a puzzle (Equihash 192,7) that graphics cards are good at. This image is a ready-to-run
mining program for one graphics card: it connects to a mining pool (yolo) on one of the Ycash
**testnets** and works on blocks there. Testnet coins are worthless; this is only about keeping the
practice networks alive.

The mining program is **lolMiner**, a free but closed-source miner. Its author keeps a **developer
fee of 1%**: about 1% of the time, the program mines for its author instead of for us. On a testnet
that costs us nothing but 1% of the speed. We do not change or remove it (its licence forbids that).

The container is told only three things: **which pool**, **a worker name** and, optionally, **which
address gets paid**. It never holds a password, a key or a token, because it runs on rented machines
whose owners can look inside it.

## What is in it

| Part | What |
|---|---|
| lolMiner | Release `1.98a` from [Lolliedieb/lolMiner-releases](https://github.com/Lolliedieb/lolMiner-releases/releases/tag/1.98a), `lolMiner_v1.98a_Lin64.tar.gz`, SHA-256 `0b8078299654a12846e4967f1db3506409cfb8b1031687a910965d1a99c6f270` (checked at build; the executable and `license.txt` are copied unmodified) |
| Base | `ubuntu:24.04` by digest. lolMiner brings its own GPU kernels and needs only the driver's `libcuda`, which the NVIDIA container runtime mounts from the host (`NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility`); a CUDA image would add about 1 GB it never loads. The archive is downloaded and checked in an Alpine stage |
| Entrypoint | [`entrypoint.sh`](entrypoint.sh) (`/usr/local/bin/ycash-miner`), runs as uid 2005 |

**Why lolMiner, and why it is right for Ycash.** Ycash's proof of work after its 2019 fork is
Equihash with n = 192, k = 7 (ycash6 `src/consensus/upgrades.cpp`, the Ycash upgrade's
`nEquihashN`/`nEquihashK`), and the BLAKE2b personalization is the string `ZcashPoW` followed by n
and k as 32-bit little-endian integers (`src/crypto/equihash.cpp`, `EhInitialiseState`). lolMiner's
`EQUI192_7` algorithm takes the 8-byte string through `--pers` and appends n and k itself, so the
entrypoint runs `--algo EQUI192_7 --pers ZcashPoW`. lolMiner 1.98a lists `EQUI192_7` ("Equihash
192/7", fee 1.0 %, takes `--pers`) in its `--list-algos` output. yolo (the pool) names lolMiner,
miniZ and gminer as the miners it serves at 192,7. miniZ was the alternative; it is not published on
GitHub with checksums, so lolMiner's pinned GitHub release is easier to verify.

**What the entrypoint sets:** `--tls off` (yolo speaks plain stratum), `--dns-over-https 0` (the pool's
name is looked up with the machine's own DNS, not sent to a third party), `--apiport 0` (no status
port), `--watchdog exit` (a hung GPU ends lolMiner with code 42, and the entrypoint restarts it, at
most 20 times; any other exit ends the container, and the fleet replaces the machine).

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `POOL_URL` | yes | the stratum pool, `host:port` or `stratum+tcp://host:port`. Refused with a `user:password@` part |
| `WORKER` | no (`ycash-miner`) | this miner's name: letters, digits, `.`, `_`, `-` |
| `PAYOUT` | no | a transparent address to be paid. See below |
| `MINER_ARGS` | no | extra lolMiner options, e.g. `--devices 0`; pool, user, password, algorithm, API and TLS options are refused |
| `MINER_DRY_RUN` | no | `1`: print the command and exit (no GPU needed) |

**Who gets paid (yolo).** Without `--payout`, a yolo pool pays each block to the miner's **stratum
username**, which must then be a transparent address; with `--payout <address>`, the pool pays that
address for every block and the username is just a name. So:
- `PAYOUT` set: the username is `PAYOUT` (`WORKER` only appears in this container's log);
- `PAYOUT` unset: the username is `WORKER`, and the pool must run with `--payout`.

The rented fleet assumes its pools run with `--payout` (the pool operator's address) and leaves
`PAYOUT` empty; a fleet whose pools pay usernames sets `payout` to a testnet transparent address. No password is ever sent: a yolo pool for these miners runs without `--password` (a stratum
password crosses the network in clear and would sit on every rented machine).

## Run it yourself (testnet only)

On a Linux machine with an NVIDIA card, its driver and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/):

```bash
docker run --rm --gpus all \
  -e POOL_URL=pool.example:3333 -e WORKER=my-rig \
  ghcr.io/<owner>/ycash-miner@sha256:<digest>
```

Replace `pool.example:3333` with a testnet pool's address and port. Check what it would run first with
`-e MINER_DRY_RUN=1` (works without a GPU). Build it locally with `make image-miner`.

This image is for the Ycash **testnets**. Mining mainnet is possible with the same program, but this
project does not run or support that.

## Licence

lolMiner is proprietary (`/opt/lolminer/license.txt` in the image): use is allowed, redistribution
only of the original, unmodified executable for mining systems (its point 3), and the developer fee
may not be removed or redirected (point 4). This image redistributes it on that basis. Everything
else in this directory is MIT, as the rest of the repository.

## Tests

`make miners-test` runs the entrypoint against a stand-in lolMiner (refusals, the exact command, the
payout rule, the restart rule) and the fleet script's tests; CI also builds the image and runs the
entrypoint in dry-run mode inside it. lolMiner itself is not run in CI (no GPU).

## Bumping lolMiner

1. Download the new `lolMiner_v<version>_Lin64.tar.gz` from the release page, `sha256sum` it, and
   compare with the SHA-256 GitHub shows next to the asset.
2. Set `LOLMINER_VERSION` (both stages) and `LOLMINER_SHA256` in the Dockerfile, and the table above.
3. Check the release notes still list Equihash 192/7 with `--pers`; merge; run `miner-image`; put the
   printed digest into the fleet file.
