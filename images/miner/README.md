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
of the time it mines for its author). **miniZ**, a second miner (CUDA; developer fee 2 % on
Equihash), runs when the fleet pins its download and asks for it (`MINER=miniz`): the fast network
mines with it, because lolMiner's OpenCL path did not see the card on Vast (GPU burst 2, below).

The container is told only three things: **which pool**, **a worker name** and, optionally, **which
address gets paid**. It never holds a password, a key or a token, because it runs on rented machines
whose owners can look inside it.

## NOTICE: we do not redistribute either miner

Neither lolMiner nor miniZ is in this image, in this repository or in any release we publish. At
start, the entrypoint downloads the miner from its **official source** (lolMiner: its GitHub
release; miniZ: the download its author publishes on miniz.cc), checks the file against the
**SHA-256 pinned** in [`miners.conf`](miners.conf) or the fleet file, and runs it unmodified,
developer fee included.
A file that does not match is deleted and not run. Each miner's licence and terms apply to whoever
runs the container; read them before you do.

## What is in it

| Part | What |
|---|---|
| Base | `buildpack-deps:noble-curl` by digest: Docker's official Ubuntu 24.04 image with `curl` and CA certificates. glibc is needed (both miners are glibc programs). Not a CUDA image: the miners bring their own GPU kernels and need only the driver's libraries, which the NVIDIA container runtime mounts from the host (`NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility`: `compute` mounts `libcuda` and the driver's OpenCL library `libnvidia-opencl.so.1`, `utility` mounts `nvidia-smi`) |
| OpenCL | `ocl-icd-libopencl1` (the Khronos ICD loader, `libOpenCL.so.1`), `/etc/OpenCL/vendors/nvidia.icd` (`libnvidia-opencl.so.1`) and `clinfo`, from Ubuntu 24.04, versions pinned. See "Why OpenCL" below |
| [`cl-probe.c`](cl-probe.c) | `/usr/local/bin/cl-probe`, ours, built in a throw-away stage: takes a miner's OpenCL start-up steps one by one (context, queue, compile lolMiner's empty `healthCheck` kernel, run it) and prints each error. See "GPU burst 2" below |
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

### GPU burst 2 (2026-11-13): the loader is there, lolMiner still counts 0

With the loader in, a rented RTX 3060 showed: `nvidia-smi` GPU 0; `clinfo -l` **Platform #0: NVIDIA
CUDA, Device #0: NVIDIA GeForce RTX 3060**; and lolMiner `OpenCL driver detected. Number of OpenCL
supported GPUs: 0`, `Cuda driver detected. Number of Cuda supported GPUs: 1`, the card listed with
`Drivers: Cuda` only. lolMiner lists a card it can drive with both as `Drivers: Cuda, OpenCL` (the
string is in its binary), so its OpenCL detection dropped a device the platform exposes. Listing is
not using: before lolMiner counts an OpenCL GPU it builds and runs a health-check kernel
(`__kernel void healthCheck() { }`, with the messages "GPU Health check failed for program build" /
"... enqueue kernel" in its binary), and on Nvidia the build loads the driver's compiler library
(`libnvidia-gpucomp.so.<driver>` on current drivers, `libnvidia-compiler.so.<driver>` on old ones),
which the container runtime mounts only if it knows it (NVIDIA Container Toolkit 1.14.0 added gpucomp
to the compute libraries). Vast also ran the container with `NVIDIA_VISIBLE_DEVICES=void` and
`NVIDIA_DRIVER_CAPABILITIES=all`, its own injection, not the values the image and the fleet set.
The entrypoint now prints, before mining: the driver version, what the runtime mounted
(`/proc/self/mountinfo`), the driver libraries in the linker cache and the ones OpenCL needs (yes/NO),
unresolved dependencies of `libnvidia-opencl.so.1` (`ldd`), the `.icd` files, `OCL_ICD_*` and
`LD_LIBRARY_PATH`, `clinfo -l` and its platform/device summary, and `cl-probe` with the libraries the
dynamic linker was asked for and did not load (`LD_DEBUG=libs`). It also counts a card listed as
`Drivers: Cuda, OpenCL` as usable for lolMiner. miniZ mines 192,7 with CUDA and does not need any of
this, which is why the fast network uses it.

### Before mining: what it sees, and no GPU means exit 70

Before it mines, the entrypoint prints: the NVIDIA variables, the `/dev/nvidia*` nodes, `nvidia-smi -L`
(UUIDs left out), the OpenCL loader, driver library and `.icd` entries, `clinfo -l`, lolMiner's own
`--list-devices` (miniZ: `--cuda-info`), the driver and OpenCL checks above, and where the pool's name resolves and whether its port accepts a TCP connection
(an unreachable pool is only a warning: lolMiner keeps retrying). If lolMiner sees no OpenCL GPU
(miniZ: `nvidia-smi` lists none, or miniZ cannot load `libcuda.so.1`), it **exits 70 without mining**, so Vast shows the rental exited
and the fleet gives it back instead of paying for an idle machine. `MINER_DIAG=1` runs the same
checks (after the download) and exits 0 or 70 without mining.

### The end of a burst (`MINER_UNTIL`)

The fleet gives every burst miner its end as `MINER_UNTIL` (epoch seconds). At that time the
entrypoint stops the miner and ends its own rental: it destroys its Vast instance, or stops it if
destroy is refused (a stopped instance pays no GPU time), with the key Vast puts in every container
(`CONTAINER_API_KEY` and `CONTAINER_ID`: per instance, able to start, stop or destroy only that
instance; https://docs.vast.ai/guides/instances/docker-environment). That key is Vast's, not ours,
and is never printed; the entrypoint prints only whether it is there (yes/no), and the miner runs
without it (`env -u CONTAINER_API_KEY -u CONTAINER_ID`). The same user can still read it from
`/proc/1/environ`, so the fleet does not rely on the label staying intact: `expire` destroys our
instances whose label lost its end time or no longer parses. Without the key the container just
exits 0 and the fleet's `expire` destroys the instance. A burst miner started after its end does
nothing but this.

### miniZ (CUDA; the fast network's miner)

`MINER=miniz` is **refused** until both `MINIZ_URL` (https, miniZ's official download) and
`MINIZ_SHA256` are set, in `miners.conf` or in the container's environment (the fleet file's
`miniz_url` / `miniz_sha256`). `miners.conf` leaves them empty: the fleet file is where they are
pinned, so enabling miniZ stays a reviewed change in ycash-ops.

| | |
|---|---|
| Version | `v2.5e3` (released 2025-10-28, the latest on https://miniz.cc/download/ on 2026-11-13) |
| URL | `https://miniz.cc/?sdm_process_download=1&download_id=5200` (the Linux x64 button; it serves `miniZ_v2.5e3_linux-x64.tar.gz`) |
| SHA-256 | `873f011442df76b9aae541f3c1a385677f5ea75d94a41da08647a7e51f92ae30` (the archive, as the download page lists it and as computed on download); the binary inside, `e458177874c95cc7853c95e65965d33adfebd6a6670ce1d9ac35bd994260f663`, is checked against the archive's own `miniZ.sha256sum` |
| Command | `miniZ --url=<worker or payout>@<host:port> --par=192,7 --pers=ZcashPoW --telemetry=0 --nocolour` |

The flags are miniZ's own: https://miniz.cc/usage/ ("--url=[[ssl://]user.worker@server:port]",
"--par= Equihash algorithm parameters", "--pers= Coin personalised string", "--telemetry= ... to
disable set port to 0"), and its FAQ, "How to mine Ycash (YEC)?": "it should not be necessary to
add --par=192,7 and --pers=ZcashPoW ... However, this may depend on the pool" (yolo does not send a
personalization, so both are given). `--help` of v2.5e3 lists the same options and spells the colour
switch `--nocolour`. Its features page lists Ycash (YEC) under 192,7 and "Developer fee:
Equihash: 2.0% ... % of mining time". `--cuda-info` lists its CUDA devices before mining. It has no
watchdog exit code like lolMiner's 42, so any failed exit restarts it (at most 20 times).

**What enabling it agrees to** (https://miniz.cc/terms-and-conditions/, read 2026-11-13): miniZ is
licensed under **CC BY-ND 4.0**; whoever uses it agrees **not to decompile, disassemble or reverse
engineer** it or tamper with the binary; it comes **as is**, without warranty or liability; the
Terms may change without notice; and it mines for its author **2 % of the time** on Equihash (its
fee servers; on a testnet this is simply 2 % of the card's time spent elsewhere). We do not
redistribute it (the container downloads it from miniz.cc at start), and the binary is run
unmodified.

Why offer it at all: a second, independent miner is software diversity (a bug in one miner does not
stop the network), and it mines 192,7 with CUDA where lolMiner needs OpenCL.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `POOL_URL` | yes | the stratum pool, `host:port` or `stratum+tcp://host:port`. Refused with a `user:password@` part |
| `WORKER` | no (`ycash-miner`) | this miner's name: letters, digits, `.`, `_`, `-` |
| `PAYOUT` | no | a transparent address to be paid. See below |
| `MINER` | no (`lolminer`) | `lolminer` or `miniz` (miniz only once pinned) |
| `MINIZ_URL`, `MINIZ_SHA256` | for miniz | miniZ's https download (a query URL is allowed: miniz.cc's link) and the archive's SHA-256 |
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
miners, miniZ from a query URL with its own checksum file checked, the payout rule, the refusals,
the restart rules, the GPU, driver and pool listing with exit 70 when lolMiner has no OpenCL GPU (a
card listed as `Drivers: Cuda, OpenCL` counts) or miniZ cannot load CUDA, and the burst end (`MINER_UNTIL`: destroy, else stop, with Vast's
per-instance key, never printed). CI also builds the image and runs its entrypoint in dry-run mode
inside it. Without a GPU, `docker run --platform linux/amd64 -e POOL_URL=<pool> -e MINER_DIAG=1
<image>` downloads lolMiner, prints the checks and exits 70.

## Bumping lolMiner (or pinning miniZ)

1. Download the new archive from the official release page, `sha256sum` it, and compare with the
   SHA-256 the release page shows.
2. Set the URL and SHA-256 (and `LOLMINER_VERSION`) in `miners.conf` and in the table above.
3. Check the release notes still list Equihash 192/7 with `--pers`; merge; run `miner-image`; put
   the printed digest into the fleet file.

miniZ is pinned in the fleet file, not here: `miniz_url` and `miniz_sha256` reach the container as
`MINIZ_URL` / `MINIZ_SHA256`. To bump it, take the Linux x64 link and the archive's sha256sum from
https://miniz.cc/download/, download it, check the sum, and change both in ycash-ops
`miners/fleet.json` (no new image). miniz.cc gives each release a new `download_id`.
