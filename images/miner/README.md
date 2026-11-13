# ycash-miner: the GPU miner launcher for the Ycash testnets

`ghcr.io/<owner>/ycash-miner`, built by [`miner-image.yml`](../../.github/workflows/miner-image.yml)
from this directory, by hand, from `upgrade/vault`.

## In plain words

A Ycash network only moves forward when someone finds blocks, and finding a Ycash block means
solving a puzzle (Equihash 192,7) that graphics cards are good at. This image runs a mining program
on one graphics card and connects it to a mining pool (yolo) on one of the Ycash **testnets**.
Testnet coins are worthless; this is only about keeping the practice networks alive.

The image does **not contain** the mining program. When the container starts, it downloads the
miner from its author's official release page, checks that the download is exactly the version we
pinned (by its SHA-256 fingerprint), and refuses to run anything else. The default miner is
**lolMiner**, a free but closed-source miner whose author keeps a **developer fee of 1%** (about 1%
of the time it mines for its author). **miniZ**, a second miner, is built in as an option but
switched off until the owner has checked its terms.

The container is told only three things: **which pool**, **a worker name** and, optionally, **which
address gets paid**. It never holds a password, a key or a token, because it runs on rented machines
whose owners can look inside it.

## NOTICE: we do not redistribute either miner

Neither lolMiner nor miniZ is in this image, in this repository or in any release we publish. At
start, the entrypoint downloads the miner from its **official source** (lolMiner: its GitHub
release; miniZ: the download its author publishes, once pinned), checks the file against the
**SHA-256 pinned** in [`miners.conf`](miners.conf), and runs it unmodified, developer fee included.
A file that does not match is deleted and not run. Each miner's licence and terms apply to whoever
runs the container; read them before you do.

## What is in it

| Part | What |
|---|---|
| Base | `buildpack-deps:noble-curl` by digest: Docker's official Ubuntu 24.04 image with `curl` and CA certificates. glibc is needed (both miners are glibc programs). Not a CUDA image: the miners bring their own GPU kernels and need only the driver's libraries, which the NVIDIA container runtime mounts from the host (`NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility`: `compute` mounts `libcuda` and the driver's OpenCL library `libnvidia-opencl.so.1`, `utility` mounts `nvidia-smi`) |
| OpenCL | `ocl-icd-libopencl1` (the Khronos ICD loader, `libOpenCL.so.1`), `/etc/OpenCL/vendors/nvidia.icd` (`libnvidia-opencl.so.1`) and `clinfo`, from Ubuntu 24.04, versions pinned. See "Why OpenCL" below |
| [`entrypoint.sh`](entrypoint.sh) | `/usr/local/bin/ycash-miner`: download, check, run (as uid 2005) |
| [`miners.conf`](miners.conf) | `/opt/ycash-miner/miners.conf`: each miner's official URL and pinned SHA-256 (public values) |

### lolMiner (the default)

| | |
|---|---|
| Version | `1.98a` |
| URL | `https://github.com/Lolliedieb/lolMiner-releases/releases/download/1.98a/lolMiner_v1.98a_Lin64.tar.gz` |
| SHA-256 | `0b8078299654a12846e4967f1db3506409cfb8b1031687a910965d1a99c6f270` |
| Command | `lolMiner --algo EQUI192_7 --pers ZcashPoW --pool <host:port> --user <worker or payout> --tls off --dns-over-https 0 --apiport 0 --watchdog exit --nocolor --timeprint on` |

**Owner: confirm the SHA-256 once** against the digest GitHub shows next to
`lolMiner_v1.98a_Lin64.tar.gz` on https://github.com/Lolliedieb/lolMiner-releases/releases/tag/1.98a.
It was computed from the download on 2026-11-01; the release page could not be read from the
machine that wrote this.

**Why it is right for Ycash.** Ycash's proof of work after its 2019 fork is Equihash with n = 192,
k = 7 (ycash6 `src/consensus/upgrades.cpp`, the Ycash upgrade's `nEquihashN`/`nEquihashK`), and the
BLAKE2b personalization is `ZcashPoW` followed by n and k as 32-bit little-endian integers
(`src/crypto/equihash.cpp`). lolMiner's `EQUI192_7` takes the 8-byte string through `--pers` and
appends n and k (the Zcash convention every Equihash miner follows); lolMiner 1.98a lists
`EQUI192_7` ("Equihash 192/7", fee 1.0 %, takes `--pers`) in its `--list-algos` output. yolo names
lolMiner, miniZ and gminer as the miners it serves at 192,7.

The other flags: `--tls off` (yolo speaks plain stratum), `--dns-over-https 0` (the pool's name is
looked up with the machine's own DNS, not sent to a third party), `--apiport 0` (no status port),
`--watchdog exit` (a hung GPU ends lolMiner with code 42 and the entrypoint restarts it, at most 20
times; any other exit ends the container, and the fleet replaces the machine).

### Why OpenCL (GPU burst 1, 2026-11-13)

lolMiner 1.98a mines Equihash 192,7 on Nvidia cards with an **OpenCL** kernel; it has no CUDA
solver for 192,7. Its binary (UPX-unpacked) carries the class `Equihash192_7_NV_Cl` and the embedded
kernel `__equihash_192_7_NV_cl_bin`, and no CUDA counterpart; its CUDA Equihash paths are Beam and
Flux (release notes 1.56: "Mining Flux and Beam on all Nvidia GPUs now uses Cuda instead of OpenCL";
1.95a lists Nvidia "Equihash 144/5 (via OpenCL)"). It opens OpenCL with `dlopen("libOpenCL.so.1")`,
the Khronos ICD loader, which reads `/etc/OpenCL/vendors/*.icd` to find the vendor library. The NVIDIA
container runtime mounts the vendor library (`compute` capability: "required for CUDA and OpenCL
applications") but not the loader, and an `.icd` file only where the host has one. The first image
had neither, so lolMiner printed `No OpenCL driver or GPUs detected.` (reproduced with lolMiner 1.98a
in that image: `--list-devices`) and never reached the pool. This image prints
`OpenCL driver detected. Number of OpenCL supported GPUs: N`, 0 without a card.

### Before mining: what it sees, and no GPU means exit 70

Before it mines, the entrypoint prints: the NVIDIA variables, the `/dev/nvidia*` nodes, `nvidia-smi -L`
(UUIDs left out), the OpenCL loader, driver library and `.icd` entries, `clinfo -l`, lolMiner's own
`--list-devices`, and where the pool's name resolves and whether its port accepts a TCP connection
(an unreachable pool is only a warning: lolMiner keeps retrying). If lolMiner sees no OpenCL GPU
(miniZ: `nvidia-smi` lists none), it **exits 70 without mining**, so Vast shows the rental exited
and the fleet gives it back instead of paying for an idle machine. `MINER_DIAG=1` runs the same
checks (after the download) and exits 0 or 70 without mining.

### The end of a burst (`MINER_UNTIL`)

The fleet gives every burst miner its end as `MINER_UNTIL` (epoch seconds). At that time the
entrypoint stops the miner and ends its own rental: it destroys its Vast instance, or stops it if
destroy is refused (a stopped instance pays no GPU time), with the key Vast puts in every container
(`CONTAINER_API_KEY` and `CONTAINER_ID`: per instance, able to start, stop or destroy only that
instance; https://docs.vast.ai/guides/instances/docker-environment). That key is Vast's, not ours,
and is never printed. Without it the container just exits 0 and the fleet's `expire` destroys the
instance. A burst miner started after its end does nothing but this.

### miniZ (optional, off by default)

`MINER=miniz` is **refused** until both `MINIZ_URL` (https, miniZ's official download) and
`MINIZ_SHA256` are set, in `miners.conf` or in the container's environment (the fleet file's
`miniz_url` / `miniz_sha256`). They are empty on purpose: miniZ's site (miniz.cc) could not be
reached from the machine that wrote this, and its Terms have not been reviewed. Enable it only after
the owner has:
1. read miniZ's Terms on miniz.cc (and its developer fee for 192,7);
2. confirmed from miniZ's own documentation that it accepts a custom personalization for 192,7;
3. downloaded the Linux archive from miniZ's official page, `sha256sum`-ed it and pinned both values.

The command the entrypoint runs is `miniZ --url=<worker or payout>@<host:port> --par=192,7
--pers=ZcashPoW`. These are the flags miniZ's documentation gives for Equihash coins (`--par=N,K`
selects the variant, `--pers=` the personalization, `--url=user@host:port` the pool) as far as we
know them; they were **not checked against miniZ's current documentation or run** here. Confirm them
(step 2) and fix this line if they differ. Its archive is unpacked and the file named `miniZ` run.
Why offer it at all: a second, independent miner on one of slow's two machines is software diversity
(a bug in one miner does not stop the network).

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `POOL_URL` | yes | the stratum pool, `host:port` or `stratum+tcp://host:port`. Refused with a `user:password@` part |
| `WORKER` | no (`ycash-miner`) | this miner's name: letters, digits, `.`, `_`, `-` |
| `PAYOUT` | no | a transparent address to be paid. See below |
| `MINER` | no (`lolminer`) | `lolminer` or `miniz` (miniz only once pinned) |
| `MINIZ_URL`, `MINIZ_SHA256` | for miniz | miniZ's https download and its SHA-256 |
| `MINER_ARGS` | no | extra miner options, e.g. `--devices 0`; pool, user, password, algorithm, personalization, API and TLS options are refused |
| `MINER_UNTIL` | no | a burst's end, epoch seconds (the fleet sets it): stop and end the rental then |
| `MINER_DRY_RUN` | no | `1`: print what would be downloaded and run, then exit (no download, no GPU) |
| `MINER_DIAG` | no | `1`: download and check the miner, print the GPU and pool checks, exit 0 (a usable GPU) or 70 |

Exit codes of the entrypoint itself: 64 a bad setting, 65 a SHA-256 mismatch (nothing run), 69 the
download failed (no network or the release moved; nothing run), 70 no usable GPU (nothing mined),
0 at a burst's end. A verified download is kept in
`~/.cache/ycash-miner` and checked again before each reuse.

**Who gets paid (yolo).** Without `--payout`, a yolo pool pays each block to the miner's **stratum
username**, which must then be a transparent address; with `--payout <address>`, the pool pays that
address for every block and the username is just a name. So:
- `PAYOUT` set: the username is `PAYOUT` (`WORKER` only appears in this container's log);
- `PAYOUT` unset: the username is `WORKER`, and the pool must run with `--payout`.

The rented fleet assumes its pools run with `--payout` (the pool operator's address) and leaves
`PAYOUT` empty; a fleet whose pools pay usernames sets `payout` to a testnet transparent address. No
password is ever sent: a yolo pool for these miners runs without `--password` (a stratum password
crosses the network in clear and would sit on every rented machine).

## Run it yourself (testnet only)

On a Linux machine with an NVIDIA card, its driver and the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/):

```bash
docker run --rm --gpus all \
  -e POOL_URL=pool.example:3333 -e WORKER=my-rig \
  ghcr.io/<owner>/ycash-miner@sha256:<digest>
```

Replace `pool.example:3333` with a testnet pool's address and port. The container downloads lolMiner
(about 14 MB) on first start. Check what it would do first with `-e MINER_DRY_RUN=1` (works without a
GPU and without downloading). Build it locally with `make image-miner`.

This image is for the Ycash **testnets**. This project does not run or support mining mainnet with it.

## Tests

`make miners-test` runs the entrypoint against a stand-in `curl` and stand-in miners (no network, no
GPU): a matching download runs, a mismatching one or a failed download refuses and runs nothing, the
cache is reused and re-checked, miniZ is refused without its pins, the exact commands for both
miners, the payout rule, the refusals, the restart rule, the GPU and pool listing with exit 70
when lolMiner has no OpenCL GPU, and the burst end (`MINER_UNTIL`: destroy, else stop, with Vast's
per-instance key, never printed). CI also builds the image and runs its entrypoint in dry-run mode
inside it. Without a GPU, `docker run --platform linux/amd64 -e POOL_URL=<pool> -e MINER_DIAG=1
<image>` downloads lolMiner, prints the checks and exits 70.

## Bumping lolMiner (or pinning miniZ)

1. Download the new archive from the official release page, `sha256sum` it, and compare with the
   SHA-256 the release page shows.
2. Set the URL and SHA-256 (and `LOLMINER_VERSION`) in `miners.conf` and in the table above.
3. Check the release notes still list Equihash 192/7 with `--pers`; merge; run `miner-image`; put
   the printed digest into the fleet file.

A fleet can also pin miniZ without a new image: `miniz_url` and `miniz_sha256` in the fleet file
reach the container as `MINIZ_URL` / `MINIZ_SHA256`.
