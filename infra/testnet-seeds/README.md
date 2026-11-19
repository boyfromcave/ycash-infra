# infra/testnet-seeds — seed hosts for the Ycash testnets (and, later, mainnet) on AWS EC2

## In plain words

A new node joining a Ycash network has to find someone to talk to first. The networks answer
that with **seed nodes**: a few always-on machines whose addresses are written into the node
program itself ("fixed seeds"). Because those addresses are compiled in, they must never change,
however many times the machines behind them are rebuilt.

There are three practice networks (testnets): **fast**, **slow** and **legacy**. One machine
serves all three, each network in its own container, on its own port, with its own data folder.
Two machines are the default. Any one network can be started, upgraded, wiped or checked without
touching the other two, and without changing any address.

This directory describes those machines for AWS in two separate pieces:

- **`ips/`, the addresses.** One fixed public address (an Elastic IP) per machine. It is created
  once and kept forever. Terraform refuses to delete one.
- **`nodes/`, the machines.** One small virtual machine per address, each with its own disk for
  the blockchains, and `seedctl`, the small tool on each machine that runs the networks.

Nothing here names an AWS account, a person or a storage bucket. The operator's real settings live
in a private repository that uses these pieces by reference ([below](#calling-it-from-a-private-repository)).
Deployment runs from that private repository's workflow, never from this one. This repository's CI
only checks that the Terraform and the scripts here are well formed and behave as written.

The machines hold no keys and no coins. A node's only secret is its own RPC password, which is
made on the machine and never leaves it.

## The two layers

| Layer | Creates | State | Torn down |
|---|---|---|---|
| `ips/` | `seed_count` Elastic IPs (`<name_prefix>-seed-<i>`), default 2 | its own state file | never (`prevent_destroy`) |
| `nodes/` | a small VPC (one public /24 per zone, no NAT), a security group, an SSM-only instance role, and per host: a network interface carrying the Elastic IP, an encrypted gp3 data volume, an instance | its own state file | any time |

`nodes/` takes the addresses as a variable (`seeds`, the `ips/` output of the same name). The
caller passes it from the `ips/` state with a `terraform_remote_state` data source, so the two
layers never share a state file and a mistake in `nodes/` cannot touch an address.

## The networks

`networks` is a map: one entry per network every host serves. The key names the network
(`yb-fast`), the profile picks everything the node has compiled in for it
(`nodes/locals.tf`, `profiles`, from the testnet plan's Revision 3 table):

| profile | node arguments | P2P / RPC | magic (prefix framing) | datadir (the node's) |
|---|---|---|---|---|
| `fast` | `-testnet -testnetprofile=fast` | 18833 / 18832 | `f77962d3` | `testnet-yb-fast` |
| `slow` | `-testnet -testnetprofile=slow` | 18933 / 18932 | `f77962d4` | `testnet-yb-slow` |
| `legacy` | `-testnet -testnetprofile=legacy` | 19033 / 19032 | `f77962d5` | `testnet-legacy` |
| `main` | none (mainnet) | 8833 / 8832 | none (no prefix) | the default |

```hcl
networks = {
  yb-fast = { profile = "fast" }                                        # the default image
  yb-slow = { profile = "slow", image = "ghcr.io/<owner>/ycashd@sha256:…" } # its own image
  legacy  = { profile = "legacy" }
  main    = { profile = "main", enabled = false }                       # for a separate mainnet stack
}
```

That is also the default. Adding or removing a network is one entry. An entry can carry its own
`image` (by digest; otherwise `image` applies), `bootstrap = false` (no prefix import) and
`extra_args`. Two enabled entries cannot share a profile, and `main` is refused beside a testnet:
mainnet is a separate stack, with its own state, addresses and (recommended) AWS account, deployed
only through an approval-gated environment (plan decision T-18).

Per network, on every host: a container `ycashd-<key>`, host networking, P2P on the profile's
port (open to `p2p_ingress_cidrs`), RPC on its own port bound to `127.0.0.1`, its datadir at
`/srv/ycash-data/<key>/node` on the data volume, its own RPC credential, and
`-externalip=<host address>`, `-addnode=<every other host on that port>` and (testnets)
`-dnsseed=0`. `extra_args` (default `-dbcache=256 -maxconnections=64`, which keeps three nodes
inside 4 GiB) applies to all of them.

### What each host is

The public names are `fastnet-seed.ycash.team` (18833), `slownet-seed.ycash.team` (18933) and `legacy-seed.ycash.team` (19033). Each name has an A record for every seed address. From outside:

```bash
nc -vz fastnet-seed.ycash.team 18833
nc -vz slownet-seed.ycash.team 18933
nc -vz legacy-seed.ycash.team 19033
```

`succeeded` means that network is accepting peers. `nc` uses one of the name's addresses; the other host is the second A record. RPC is not reachable at these names.

- **Inbound:** the P2P port of each enabled network, and nothing else. No SSH, no RPC. A shell is
  `aws ssm start-session --target <instance id>` (SSM Session Manager; the instance role has
  `AmazonSSMManagedInstanceCore` and nothing more).
- **Outbound:** open (peers, the image registry, Ubuntu's mirror, the prefix release, SSM).
- **Instance:** Ubuntu 24.04 LTS (Canonical's AMI from AWS's public SSM parameter), default
  `t3a.medium` (2 vCPU, 4 GiB, x86_64) with a 4 GiB swap file, a 20 GiB root and an 80 GiB data
  volume. IMDSv2 required, hop limit 1, both volumes encrypted.
- **First boot** (`files/setup.sh`, cloud-init): installs Docker, mounts the data volume
  (formatting it only if it has no filesystem), installs `seedctl` and two systemd units (start
  the networks at boot; check the prefix imports every 10 minutes), then starts every network
  the data volume already carries. A new volume carries none: the deploy workflow starts them.
- **Testnet nodes run with `-maxtipage=999999999`** (`nodes/locals.tf`, before `extra_args`):
  a seed restarted while its testnet has gone over a day without a block would otherwise think
  it is still syncing and ignore newcomers' header requests (`images/ycashd/README.md`, "Keeping
  a quiet testnet alive"). Mainnet nodes keep the default.

## Per-network lifecycle: `seedctl` through SSM Run Command

A network is not an AWS resource. The module outputs, per network, the document `seedctl`
applies (`network_configs`: image, ports, arguments, peers, prefix, and the optional `insight`,
`zmq_port` and `explorer`) and `seedctl` itself (`seedctl`, gzip + base64), plus `host_files`: the
other files an apply or a reset needs (the prefix tools; for an explorer `seedctl-explorer` and
the Inzyght build context), one gzip + base64 JSON map. The operator's deploy workflow installs
that `seedctl` on every host, hands `host_files` to `seedctl install-files`, and runs one command
there through **SSM Run Command** (no SSH, no inbound port):

| | Command on each host | What happens | Other networks |
|---|---|---|---|
| deploy | `seedctl apply <net> <config>` (`sync <all>` for every network) | creates the network's directory, its RPC credential, bootstraps an empty datadir from the prefix, pulls the image, starts the container, waits for RPC | untouched |
| upgrade (image) | `seedctl apply <net> <config>`, one host at a time | the container is recreated on the new image with the same data; the next host goes only after this one answers RPC | untouched |
| reset | `seedctl reset <net> <config>` | stops the container, deletes that network's datadir, bootstraps again from the host's verified prefix cache (nothing downloaded twice), starts it | untouched |
| status | `seedctl status [<net>]` | one JSON line per network: container, image, chain, blocks, headers, progress, peers, inbound | n/a |
| stop | `seedctl stop <net>` | stops the container; the data stays | untouched |

`seedctl sync` applies every configured network and stops (never deletes) any network that is no
longer configured. Each host serialises seedctl runs with a lock, so the prefix timer, a boot and
a workflow run never interleave. `status` never takes the lock, so it answers at once even while a
long run holds it; a workflow sends it no host files.

`seedctl install-files <file>` writes only the module's own host files (`prefix-restore.sh`,
`frame.py`, `seedctl-explorer`, `inzyght-build.json`, modes 0644 or 0755): any other name, a path
separator or `..` is refused before anything is written, so a payload can never replace
`seed.env`, `setup.sh` or `seedctl`. One file or several per call, so a workflow may split them
across commands. An instance made by this module revision has the prefix tools only from there
(not in user_data): an apply or a reset that must bootstrap an empty datadir without them fails at
once, naming the missing file, instead of retrying a script that is not there. A caller's root
must therefore export `host_files` (below) and its workflow install it before every run that
changes something (not before `status`). While a detached run (below) holds the host's lock,
`install-files` waits for nothing: it fails at once with `a detached run is still going: phase
<phase> (seedctl <command>, since <time>); run status`, so a second deploy ends in seconds instead
of waiting out the workflow's command timeout. Held by anything else (the prefix timer, a boot),
it waits up to 9 minutes.

`seedctl detach apply|reset|sync …` starts the same command as the transient systemd unit
`ycash-seedctl-job` and returns at once (it refuses while one is running, with the same message as
`install-files`); `status` then carries a
`job` field (`command`, `state` running / succeeded / failed / interrupted, `phase`, `started`,
`finished`, and on a failure the error line), and the job's output is in
`/srv/ycash-data/job.log` (0600) and the unit's journal. A workflow uses it where a run would
otherwise keep a billed runner waiting for a long first start (the explorer host's build and
import); without `detach` nothing changes. Before the host's first `applied.json` (a first deploy
still going, or `interrupted` by a reboot) `status` with no network prints one line,
`{host, ip, job}`, and `status <net>` that network's line with its `job`; a host that never ran
a detached job prints what it printed before.

**Why this, and not per-network volumes or instance replacement.** The alternatives were a
Terraform `-replace` of a data volume (the single-network design: it replaces the instance, so a
reset of one network would restart every network on the host) or one EBS volume per network
(a volume attached to a running instance still needs on-host work to format, mount and wipe it,
and every added network adds a volume and an attachment to each host). With one data volume per
host and one directory per network, a reset is `rm -rf` of one directory plus a re-import from
a prefix the host has already verified; an upgrade is one `docker compose up -d`. Terraform keeps
the desired state (images, networks, ports) and the security group; nothing about a network
forces an instance or a volume to change. The cost: networks on one host share its disk and
memory (sized for three), and the workflow, not `terraform apply` alone, starts the containers.

## What survives what

| | Upgrade of a network | Reset of a network | Add or remove a network | New module version | `terraform destroy` of `nodes/` |
|---|---|---|---|---|---|
| Elastic IPs | kept | kept | kept | kept | kept (other layer) |
| Network interface, instance | kept | kept | kept | kept (seedctl is reinstalled by the workflow) | removed |
| Data volume | kept | kept | kept | kept | removed |
| That network's chain | kept | **deleted**, re-imported | removed network: stopped, kept | kept | removed |
| The other networks | untouched | untouched | untouched | untouched | removed |

The instances read their user_data at creation only (`ignore_changes`), so bumping the module
never replaces every host at once; a host whose data volume is replaced is replaced with it.
To rebuild one host deliberately: `terraform apply -replace='module.nodes.aws_instance.seed["seed-0"]'`
(destroy-then-create: the volume and the network interface can each belong to one instance). It
comes back with the same address and the same data volume, and its `seedctl boot` restarts every
network at the version it last ran.

**Retiring an address** (deliberate, rare): in the `ips/` root,
`terraform state rm 'module.ips.aws_eip.seed["seed-2"]'`, then release it in the EC2 console.
A lower `seed_count` alone is refused.

### The prefix bootstrap

With `prefix` set, a testnet network's empty datadir is filled from the published, magic-neutral
prefix its profile restores, read from the testnet chart's values files (the single source:
`prefixRestore` `baseUrl`, `sha256sums`, `network`, `lastHeight` in `values-yb-fast.yaml`,
`values-yb-slow.yaml`, `values-legacy.yaml`):

| profile | prefix | network (`frame.py --network`, `PREFIX_NETWORK`) | last height |
|---|---|---|---|
| fast | `testnet-prefix-v1` | `zcash-testnet` | 510,247 |
| slow, legacy | `mainnet-prefix-v1` (~18.7 GB chunks, ~23.1 GB framed per network) | `ycash-mainnet` | 3,079,999 (H_S) |

Fields set in `prefix` override the chart's values for fast only. The host downloads each prefix
once into `/srv/ycash-data/prefix-cache/<network>` with the testnet chart's own `prefix-restore.sh`, which
refuses unless `SHA256SUMS` hashes to the pin, every file checks and the manifest names that network
and last height. Each network then frames it
with its own magic (`bundles/prefix/import/frame.py`, which checks every block again) and imports
it with `-loadblock`; the timer drops the flags and the framed copies once the node reaches
`last_height`. Both scripts come from the same commit of this repository as the module, in the
`host_files` output: the workflow installs them before every run (only an apply or a reset uses
them), so they are not in user_data, which EC2 caps at 16 KB. A refused
bundle stops that network's apply, never another network. The magic must be the one compiled
into the image for that profile; `prefix_magic_overrides` exists only for an image built before
the profiles (its single testnet magic, `fa1af9bf`).

## The pool (a network's `pool`)

The same module, called a second time from its own root with its own state, makes a **pool host**:
one machine that runs a testnet's mining pool, [yolo](https://github.com/boyfromcave/yolo), beside
a node of its own. Rented GPU miners (`infra/vast-miners`) connect to the pool; the pool hands them
work from its node and sends the blocks they find back to its node, which relays them to the seeds
like any other node. The pool host is never a seed: it has its own address, its own state and its
own deploy layer, so nothing done to it can touch a seed host, and the seed hosts stay P2P-only.

```hcl
module "pool" {   # e.g. the operator's testnet-pools/nodes root, one host, fast only
  source            = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds             = data.terraform_remote_state.ips.outputs.seeds    # its own ips root, one address
  name_prefix       = "testnet-pool"
  vpc_cidr          = "10.78.0.0/16"
  instance_type     = "t3a.small"
  data_volume_size  = 30
  swap_mb           = 2048
  p2p_ingress_cidrs = []                       # the pool's node only connects out
  networks = {
    yb-fast = {
      profile    = "fast"
      extra_args = "-listen=0 -addnode=<the network's seed name>:18833"
      pool       = { image = "ghcr.io/<owner>/yolo@sha256:...", payout = "sm...", port = 3333, share_ratio = 32 }
    }
  }
  prefix = { ... }                             # the same testnet-prefix-v1 pin as the seeds
  # ...
}
```

What a `pool` adds, per host:

- **The node** is the network's ordinary container (`ycashd-<key>`, the same image and the same
  prefix bootstrap as a seed: testnet-prefix-v1, then the blocks after 510,247 from the seeds),
  with `-disablewallet -mineraddress=<payout> -minetolocalwallet=0` appended: it builds block
  templates that pay `payout` and holds no key. No `txindex` or insight index (`getblocktemplate`,
  `submitblock`, `validateaddress` and `getblockchaininfo` need none).
- **yolo** in the same compose project (`yolo-<key>`, host networking, uid 2004, read-only root,
  no capabilities, 256 MiB): `--payout <payout>` (every block pays that transparent address; a
  miner's stratum username is only a worker name), stratum on `0.0.0.0:<port>` with at most 64
  sockets in all and 4 per address (`--max-connections 64 --max-per-ip 4`), its status page on
  `127.0.0.1:<port + 1>` (`--status-bind 127.0.0.1`, explicit), `--share-ratio <share_ratio>` when above 1 (shares keep GPU miners
  connected between blocks and show the fleet's speed; yolo README, "Shares"), the node's RPC on `127.0.0.1` with the node's own credential from
  `/srv/ycash-data/<key>/pool.conf` (mode 0400, never on a command line). It reaches the node
  only through the stock mining RPCs (and, in per-miner mode, `getcoinbasetemplatefor`; workspace rule 2). Host networking means the metadata
  service's hop limit of 1 does not stop yolo, so an iptables owner rule refuses uid 2004 the
  metadata addresses (169.254.169.254 and fd00:ec2::254): seedctl installs it before it starts yolo,
  and `setup.sh`'s `ycash-imds-guard.service` from every boot on, before Docker starts.
- **Inbound**: the stratum port, to `pool_ingress_cidrs` (default everyone: rented miners come
  from arbitrary addresses). Plain TCP stratum, no TLS, no password: nothing secret crosses it
  (the miners send a worker name and solutions; the payout address is the pool's), and yolo bounds
  what any connection can do (connection caps per IP and in all, an 8 KiB line limit, authorize
  and bad-submit limits, every submit's hash checked before the node sees it; yolo's README,
  "Exposure").
- **seedctl** runs both containers together (`apply`, `reset`, `stop`, `sync`, `boot`); `apply`
  also waits for yolo's status page; `status` adds a `pool` field (container, image, node up,
  height, miners, accepted, rejected, stale, highHash, shares, share ratio, last verdict, payout,
  and yolo's per-miner fields `minersByKind`, `minerList`, `coinbaseCall` and `pairs`, and its pacing
  fields `minBlockInterval`, `nextBlockInSeconds`, `held` and `heldStale`, null from a yolo without
  them).
  `stale` (a job the chain has moved past) and `highHash` (a hash above the share target, which
  GPU miners send now and then; never a valid block) are not refusals and are not in `rejected`.

### Per-miner mode (`per_miner = true`)

By default the pool pays every block to `payout`. With `per_miner = true` it pays **each miner at
its own address**: yolo runs without `--payout`, and a miner's stratum username is its payout
address, transparent (`sm…`, `s2…`), Sapling (`ytestsapling1…`) or post-quantum (`tqf…`, `tqs…`),
optionally `<address>.<label>` (a label of 1 to 32 of `A-Z a-z 0-9 _ -`, shown on `status` only).
yolo checks the username with the node's `validateaddress` / `z_validateaddress` on
`mining.authorize` and refuses anything else: there is **no fallback address** for a username that
is not one (yolo README, "Which address gets paid"). A transparent miner is paid by rewriting
`vout[0]` of the node's own coinbase; a Sapling or post-quantum miner by a **paired job**, the
coinbase the node builds for it with `getcoinbasetemplatefor`, which needs ycashd 6.22.0-beta3 or
later (on an older node yolo starts, reports `"coinbaseCall": false` and refuses Sapling and
post-quantum usernames; transparent ones still work) and a yolo with paired jobs (yolo#16 or later;
an older image refuses the new options and does not start).

```hcl
      pool = {
        image                = "ghcr.io/<owner>/yolo@sha256:..."   # yolo upgrade/vault b3abf81 or later
        payout               = "sm..."   # still required: the node's -mineraddress
        per_miner            = true
        coinbase_concurrency = 2         # default 2, 1-64: yolo --coinbase-concurrency
        max_paired_per_ip    = 8         # default 8, 1-4096: yolo --max-paired-per-ip
        port                 = 3333
        share_ratio          = 32
      }
```

- `payout` stays: it is the node's `-mineraddress`, so `getblocktemplate` still carries a coinbase;
  yolo checks every paired coinbase against it (height, fees, total, fund output) and swaps a
  transparent miner's script into it. Nothing is paid to it in this mode unless a miner mines under
  that address.
- `coinbase_concurrency`: `getcoinbasetemplatefor` calls in flight at once (each Sapling one costs
  the node a proof, a few seconds on a `t3a.small`; keep its CPU credits `unlimited` while Sapling
  miners run). yolo wants the node's `-rpcthreads` at least this plus 2: the node's default, 4,
  covers the default 2; above 2 the module appends `-rpcthreads=<n + 2>` itself, and refuses a
  `-rpcthreads` in the network's `extra_args`.
- `max_paired_per_ip`: distinct Sapling and post-quantum addresses one source IP may mine to at once
  (each costs the node a coinbase per block); further ones are refused at `mining.authorize`.
  `--max-per-ip 4` (sockets per IP) still applies and is the tighter bound here.
- The Sapling proving parameters: ycash6 images carry them built into the binary (`images/ycashd`
  README), so a pool node on a ycash6 image needs nothing more; `-disablewallet` does not affect
  `getcoinbasetemplatefor`. A ycash-dd (4.5.0 line) image would need them in `~/.zcash-params` and
  has no `getcoinbasetemplatefor`; it is not a per-miner pool node.
- The node's `-ydf` (its voluntary development-fund share past the mandate end) is the network's
  `extra_args`: the module neither sets nor reads it, and every paired coinbase carries exactly the
  share the node's own coinbase does.
- Switching mode recreates the yolo container only (its command line changes); the node is
  recreated only when its arguments change (`-rpcthreads` above a concurrency of 2). Check with
  `status`: `pool.payout` is `"username"` and `pool.coinbaseCall` is `true`.

### Block pacing (`min_block_interval`)

A testnet whose difficulty has fallen to the minimum gives one rented GPU a block every second or
two, and the difficulty then climbs out of reach of every CPU. `min_block_interval = S` (a whole
number of seconds, 0-300; default 0, off) runs yolo with `--min-block-interval S`: the pool submits
a block it finds no sooner than S seconds after that block's job time, so its blocks' header times
are at least S seconds apart and the difficulty stays near where it was (yolo README, "Block
pacing"). Miners notice nothing; the held block's coinbase pays its finder in full, as without
pacing. It needs a yolo with block pacing (yolo#19 or later; an older image refuses the option and
does not start), and yolo refuses it on any chain but a testnet or regtest (the module only puts a
pool on a testnet profile).

```hcl
      pool = {
        image              = "ghcr.io/<owner>/yolo@sha256:..."   # yolo with block pacing (yolo#19)
        payout             = "sm..."
        share_ratio        = 32
        min_block_interval = 60         # default 0 = off, 0-300: yolo --min-block-interval
      }
```

- 0, given or left out, passes no flag: the host's config and compose file are exactly those of a
  pool without the setting.
- Setting, changing or removing it recreates the yolo container only (its command line changes);
  the node and the instance are untouched. Check with `status`: `pool.minBlockInterval` is S, and
  `pool.nextBlockInSeconds` and `pool.held` show the next release.
- It paces only this pool's blocks. Another miner on the same network is not slowed, and a block
  from elsewhere drops a held one (`heldStale`).

The image is `ghcr.io/<owner>/yolo`, built from the yolo repository at one commit on its
`upgrade/vault` by `yolo-image.yml` with [`images/yolo/Dockerfile`](../../images/yolo/Dockerfile).

### Pool quotes (`quote`)

A pool that quotes puts the YEC/USD price in its blocks' coinbase tag (in the scriptSig),
which is how a Yellowback network learns the price from its miners (ycash6
`doc/yellowback-mining.md` §3-§4). `quote = { image = ... }` (default null, off) runs the Yellowback
quote agent, `yellowback-quote` (ycash6 `contrib/yellowback`), beside the node, in the same compose
project (container `quote-NET`, uid 2005, read-only, no capabilities, host networking with the
metadata rule, outbound HTTPS to the public price sources only, nothing listening), and gives the
node `-yellowbackpayoutaddress=<payout>`:

```hcl
      pool = {
        image  = "ghcr.io/<owner>/yolo@sha256:..."
        payout = "sm..."                 # must be P2PKH (sm..., 35 characters) with a quote
        quote = {
          image             = "ghcr.io/<owner>/ycash-quote@sha256:..."   # quote-image.yml
          poll_seconds      = 75         # default (the block time); 30-600: fetch and yed_setquote every poll
        }
      }
```

- **The payout key needs no key on the host.** The tag names the payout address as a 20-byte key
  hash, and the Yellowback fees the tag earns are paid to P2PKH of it. The pool's node holds no
  wallet (`-disablewallet`); `-yellowbackpayoutaddress` (and `-mineraddress`) only name the
  address. Its key stays where the payout address was made (for the fast-testnet pool, the lead
  architect's own wallet); never put it on the host or in a repository. Today's tag (version 1)
  carries a P2PKH key hash, so the payout must be transparent P2PKH; a tag version 2 with a
  post-quantum payout key is planned for beta4 (item 3f), and this check follows it then.
- **Before Yellowback is active on the network** (testnet-yb-fast until its attestor set is compiled
  into the nodes, beta4 item 3e) the node ignores `-yellowbackpayoutaddress` (it logs that the
  Yellowback options are ignored), has no `yed_*` calls and emits no tag; the agent logs once that
  Yellowback is not active and asks again every poll, so the pool runs exactly as without quotes
  and starts quoting by itself when the network's release turns Yellowback on. `status` shows
  `pool.quote.quoteKind` null until then, and `"quote"` while the node holds a fresh quote.
- **Cadence.** The agent fetches the price and calls `yed_setquote` every `poll_seconds`, so the
  tag's price is never older than one poll. A new price changes the tag, so yolo sends every miner
  one new job (`clean_jobs`); the same price again changes nothing (yolo `tests/regtest_pairs.rs`). The image must be built from a ycash6 commit
  with this cadence (the beta4 agent): its build checks for it and fails on an older tree.
- Its configuration is `NET/quote.toml` on the data volume: `[node]` (127.0.0.1 and the node's own
  credential, mode 0400, readable by the agent's uid only) and `[quote]`; the price sources are the
  image's, cut at build time from the agent's sample configuration in the same ycash6 commit.
  Setting, changing or removing `quote` recreates the agent container and restarts the node (its
  arguments change); removing it removes the container and the file.

The image is `ghcr.io/<owner>/ycash-quote`, built from the ycash6 repository at one commit on its
`upgrade/vault` by `quote-image.yml` with [`images/quote/Dockerfile`](../../images/quote/Dockerfile).

## The attestors (a network's `attestors`)

Yellowback's price comes from a bonded set of price attestors (workspace
`docs/plans/beta4/price-feed.md` §1): each seat's agent signs a 74-byte statement every 10 blocks
and publishes it; wallets put 4 to 6 of the drawn seats' statements into every mint and claim. The
house seats run on **three hosts in three regions, three seats each** (decisions D-1, D-2): no host
holds enough seats to stop the feed (a mint needs 4 live seats among the 6 drawn of 9; one host down
leaves 6), and no key is on two hosts. `attestors = { ... }` (default none) turns a host into one of
them:

```hcl
    yb-fast = {
      profile    = "fast"
      extra_args = "-addnode=fastnet-seed.ycash.team:18833"
      attestors = {
        image = "ghcr.io/<owner>/ycash-attest@sha256:..."   # attest-image.yml
        seats = [                                          # this host's seats: public (seq, member key)
          { seq = 0, memberkey = "02..." },
          { seq = 3, memberkey = "03..." },
          { seq = 6, memberkey = "02..." },
        ]
        peers            = ["<64-hex iroh endpoint id>", ...]   # the other agents, to form the swarm
        every_blocks     = 10    # default: sign every 10 blocks
        heartbeat_blocks = 576   # default: half the fast testnet's livenessWindow (D-4: 1,152)
        # backend = "node" (default) | "lightwalletd" (the light attestor, below)
      }
    }
```

What runs (seedctl's attest half, [`files/seedctl-attest`](nodes/files/seedctl-attest)), in the
network's compose project, host networking, uid 2006, read-only, no capabilities, the metadata rule:

| Container | What |
|---|---|
| `ycashd-NET` | the network's node, **with its wallet**: it holds the seat keys and signs (`yed_signattestation`); its signing guard `<datadir>/yellowback/attest-signed.dat` refuses a second price for a height it signed. No inbound P2P (the module opens no port for an attestor network) |
| `attest-SEQ-NET` | one `yellowback-attest attest` per seat: its private configuration `NET/attest/seat-SEQ.toml` (the node's RPC credential, mode 0400), its state `NET/attest/seat-SEQ/` (its iroh key, so its endpoint id survives a new instance; the cancel watcher's state) |
| `attsub-NET` | (`subscribe`, default true) one `yellowback-attest subscribe`: every statement the topic carries goes into this node's pool, so the node sees the whole feed (the monitoring view) and can build bundles itself |

- **Seat keys never pass through Terraform, user_data, SSM parameters or git.** The config carries
  only each seat's seq and member key (public). The keys reach the node's wallet on the host:
  - **delivered** (the ceremony's key files, `contrib/testnet/ceremony` `<network>-seat-N.json`,
    split 3/3/3): an operator opens an SSM session on the host, writes the file under
    `/srv/ycash-data` (root only), and runs `seedctl attest-import NET FILE`. It checks the file is
    for this network and that every key is one of this host's configured seats (one key, one host),
    imports the WIF through ycash-cli's standard input (never a command line), checks the wallet
    then holds it at the recorded address, and deletes the file. The ceremony host deletes its copy.
  - **born on the host**: `seedctl attest-newkey NET` makes a key in the node's wallet and prints only
    its address and member key, which the set's `SET_JOIN` then names (`set_join <setid> <bond>
    <lock> <memberkey>` from any funded wallet). That key has no copy anywhere until exported.
  - **backed up**: `seedctl attest-export NET` writes the host's seat keys **and its signing guard**
    to one root-only file under `NET/attest/export/` and prints its path and sha256, never the
    content; copy it off over the SSM session, keep it offline, delete it on the host.
- **Restoring a host** (a lost instance or volume; runbook in ycash-ops `docs/testnet-attestors.md`):
  fence the old host first (it must never sign again), then `seedctl attest-import NET <bundle>` on
  the new one. The guard goes in before the keys (with a key and no guard an agent could sign a
  height the old host signed, at another price: equivocation, and the bond is frozen), with the
  node stopped (it reads the guard at startup), only where Yellowback is live (before that the node
  refuses to start with a wallet beside a `yellowback/` directory, init.cpp H6), and never over a
  different guard. A seat whose host was away longer than the set's livenessWindow is DORMANT:
  `yed_revive` or `set_heartbeat` per seat.
- **A reset keeps the seats.** `reset` deletes the chain only: the wallet and the guard move to
  `NET/attest/keep` and return after the bootstrap (as an x402 host's faucet wallet).
- **The fee wallet.** Heartbeats (every `heartbeat_blocks`) and cancels are paid from the node's
  wallet: `seedctl attest-fund NET` prints its fee address and balance; keep a few YEC there.
  Status shows `walletZat`.
- **Before Yellowback is live** (the fast testnet until beta4 compiles the set id in, item 3e) the
  node runs and syncs, the agents log that there is no attestor set and ask again; deploy the hosts
  ahead of the release, with `seats = []` until the ceremony.
- **Monitoring.** `status` adds `attestors`: the backend, Yellowback's state at the node (height,
  ARMED, seated count), the fee wallet, `heldSeqs` (every member of the set whose key this wallet
  holds, configured here or not: the inventory check across hosts), and per seat (`mine`) its
  agent's container, whether the wallet holds its key, its member record (status, seated, poolFresh,
  blocks since its last act) and **the age in blocks of its newest statement** in the node's pool;
  `others` the same for the set's other members. `seedctl attest-health NET [MAX]` exits 1, naming
  the seat, when an agent is not running, a key is not held, or a statement is older than MAX
  blocks (default 2 x every_blocks + 2). The workspace's ycash-ops renders the three hosts' status
  as one table (`scripts/attestors.sh view`).
- **The light backend** (`backend = "lightwalletd"`, `lightwalletd = ["https://a", "https://b"]`, two
  different servers; plan D-6, B-T3, not built yet): no node on the host and no prefix; each agent
  gets a `[backend]` table (the two endpoints, its key file `seat.key` and guard file in its state
  directory, which `attest-import` fills from the same key files). seedctl first runs the image's
  `check-config` on it and refuses, with the reason, an image whose agent does not accept the table,
  so the switch is safe before B-T3 ships; the table's exact fields are this module's proposal to
  B-T3, and follow it when it lands.
- **Local rehearsal:** [`nodes/tests/attestors-regtest.sh`](nodes/tests/attestors-regtest.sh) runs one
  host for real (Docker, regtest, seedctl as on an instance, three seats): the set and its seats from a
  ceremony node, `attest-import`, statements in both nodes' pools, status and health, an agent
  stopped, a reset, and a lost host restored from its export that refuses to re-sign a height at
  another price. It uses two regtest-only knobs the module never emits (a `bus` directory transport
  and a `mock_price`), refused by seedctl on any node without `-regtest`.

The image is `ghcr.io/<owner>/ycash-attest`, built from the ycash6 repository at one commit on its
`upgrade/vault` by `attest-image.yml` with [`images/attest/Dockerfile`](../../images/attest/Dockerfile).

## The explorer (a network's `explorer`)

The same module, called from a third root with its own state, makes an **explorer host**: one
machine that runs a public block explorer, [Inzyght](https://github.com/miodragpop/inzyght)
(unmodified), beside a node of its own, at a public HTTPS name. It is the local stack of
[`explorer/`](../../explorer/README.md) (`explorer/compose.yaml`) rendered by seedctl instead of
`make explorer-up`: the same four services, the same networks, the same hardening. Like the pool
host it is never a seed: its own address, state, deploy layer and role.

```hcl
module "explorer" {   # e.g. the operator's testnet-explorer/nodes root, one host, fast only
  source            = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds             = data.terraform_remote_state.ips.outputs.seeds    # its own ips root, one address
  name_prefix       = "testnet-explorer"
  vpc_cidr          = "10.79.0.0/16"
  instance_type     = "t3a.medium"
  data_volume_size  = 40
  p2p_ingress_cidrs = []                       # the explorer's node only connects out ("Inbound P2P": ["0.0.0.0/0"])
  networks = {
    yb-fast = {
      profile    = "fast"
      extra_args = "-listen=0 -addnode=<the network's seed name>:18833"   # with p2p_inbound: no -listen
      insight    = true                        # -txindex -insightexplorer, before the first import
      explorer = {
        hostname       = "<the explorer's name>"   # its A record points at the host's address
        build          = { repo = "https://github.com/miodragpop/inzyght", commit = "<40-hex sha>" }
        postgres_image = "postgres:17-alpine@sha256:..."
        proxy_image    = "caddy:2.10-alpine@sha256:..."
        # node_mem_limit_mb = 2304                 # the node container's limit (default), "Host size"
        # p2p_inbound = true                       # accept inbound P2P (default false), "Inbound P2P"
      }
    }
  }
  explorer_acme_email = var.acme_email         # optional certificate contact; from a secret, never committed
  prefix = { ... }                             # the same testnet-prefix-v1 pin as the seeds
}
```

What an `explorer` adds, per host (`files/seedctl-explorer`, seedctl's explorer half):

| Container | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| `ycashd-<key>` | the network's node image | uid 2001, read-only root, no capabilities | `backend`, `edge` | `YCASHD_INSIGHT=1`; RPC bound inside the container, allowed for Inzyght's fixed address only (`172.31.250.12`; and loopback, for `seedctl`'s `docker exec`); no published port (with `p2p_inbound`: the network's P2P port only, "Inbound P2P"); ZMQ `hashblock`/`hashtx` on its fixed `backend` address (.11) once the prefix is imported; `-disablewallet` (and the root's `-listen=0` without `p2p_inbound`), P2P out through `edge`; `node_mem_limit_mb` (2304 MiB) plus 2 GiB of swap ("Host size") |
| `postgres-<key>` | `explorer.postgres_image` (by digest) | the image drops to `postgres`; every capability dropped but the five its entrypoint needs; 768 MiB | `backend` | data in `/srv/ycash-data/<key>/explorer/pg` on the data volume; the database and a non-superuser owner role made at its first start (explorer's `postgres-init/10-inzyght.sh`); Inzyght's tuning values; healthcheck over TCP |
| `inzyght-<key>` | built on the host, or `explorer.image` by digest | uid 2005, read-only root, no capabilities, `mem_limit_mb` (768) | `backend` only (fixed .12) | applies and checks its schema on every start; trusts `X-Forwarded-For` from the proxy's fixed address only; started once the prefix is imported and only when its image is on the host |
| `proxy-<key>` | `explorer.proxy_image` (Caddy, by digest) | uid 2006 (its data directories handed to it by seedctl), every capability dropped but binding low ports, read-only root, 128 MiB | `backend` (fixed .10), `edge` | the only published ports, TCP 80 and 443 (HTTP/3 off); Let's Encrypt certificate for `hostname` (HTTP-01), renewal, redirect to HTTPS, HSTS on HTTPS, JSON access log, header and idle timeouts, a 1 MB body limit (explorer/Caddyfile); certificate in `/srv/ycash-data/<key>/explorer/caddy` (kept across resets and new instances, so the certificate authority's rate limits are never met); a plain 503 page while Inzyght is not up |

- **Networks.** `backend` (`172.31.250.0/24`; the proxy at .10, the node at .11 and Inzyght at .12 fixed, the value-pools service at .13 when `explorer.pools` is set, every other container from `.128/25`) is internal: no route out, so Inzyght's hard-coded
  peer-location call (`http://ip-api.com/batch`) cannot leave the host and PostgreSQL has no
  egress. `edge` (`172.31.251.0/24`) carries the node's outbound P2P and the proxy's ports. Nothing
  listens on the host's own interfaces but the proxy (and, with `p2p_inbound`, the node's P2P port). The containers are not in host networking,
  so the metadata service's hop limit of 1 already denies them an IMDSv2 token; seedctl also
  inserts a `DOCKER-USER` rule refusing both subnets the metadata address (on every apply, boot
  and prefix check that renders the explorer). Every container's Docker log is capped (20 MB x 3).
- **Where the metadata rule does not reach, and why that is safe.** The rule covers the two
  explorer subnets only, and only once seedctl has rendered them: not the Inzyght build (BuildKit's
  containers run on Docker's default bridge, and its clone steps need the network), and not the
  boot window, in which Docker restarts the containers (`restart: unless-stopped`) before
  `seedctl boot` re-inserts the rule (iptables rules do not survive a reboot). Both stay out of the
  instance's credentials anyway: the instance allows IMDSv2 only (`http_tokens = "required"`) with
  a PUT response hop limit of 1, and every one of those containers sits behind Docker's NAT, one
  hop further, so the token response never reaches it, and without a token IMDS answers nothing.
  The rule is the second layer for the long-running containers.
- **Inzyght holds the node's full RPC credential** (its `inzyght.env`): the node has no wallet
  (`-disablewallet`), so there are no keys or funds behind it, but the credential admits every
  other RPC, including `stop`, `setban` and `addnode`. A compromised Inzyght could stop or
  disconnect the explorer's own node; it cannot reach another host's node (each has its own
  credential) or anything beyond the internal network.
- **Secrets** are made on the host at the first render and never leave it: the node's RPC
  credential (`rpc.env`, as for every network), and in `/srv/ycash-data/<key>/explorer/` (mode
  0700) `pg.env` (the PostgreSQL superuser's and Inzyght's database passwords) and `inzyght.env`
  (Inzyght's copy of the RPC credential and its database password), both 0400. None is in the
  Terraform state, the module's outputs, a rendered compose file or a command line.
- **The restore trap** (explorer E1 report, D-N1): the image's `ycash-bootstrap` imports with the
  node's `ycash.conf`, so a peer there breaks the restore. seedctl does not use `ycash-bootstrap`:
  it frames the prefix itself and imports it with `-loadblock`, and every peer and the ZMQ
  endpoints are on the node's command line (`YCASHD_EXTRA_ARGS`), never in `ycash.conf`. A node
  started with `-txindex -insightexplorer` before its import builds both indexes as it imports (E1).
  ZMQ is published and Inzyght started only after the import (`prefix-check`), so Inzyght never
  indexes a chain that is still being loaded.
- **Inbound:** 443 and 80 to `explorer_ingress_cidrs` (default everyone). Nothing else, unless
  `p2p_inbound` is set: then the network's P2P port to `p2p_ingress_cidrs` too ("Inbound P2P").
  Without `p2p_inbound` no P2P rule is made for the explorer's network whatever
  `p2p_ingress_cidrs` holds (its node publishes no port to open).
- **Inbound P2P (`explorer.p2p_inbound`, default false).** The explorer's node accepts inbound
  peers, so nodes of that network can peer with it and show on the explorer's network page (which
  lists the node's own peers). Three things together, never one without the others:
  - **listen:** the node listens (the image's `listen=1`); the module refuses `p2p_inbound` with a
    `-listen` or `-nolisten` in the network's or the module's `extra_args` (seedctl refuses it
    too), since `-listen=0` would leave the opened port without a listener and also stops the node
    advertising itself (`GetLocal` returns nothing when not listening, ycash6 `src/net.cpp`);
  - **the published port:** compose publishes the network's P2P port, and only it, as
    `0.0.0.0:<port>:<port>/tcp` (IPv4 only; RPC and ZMQ stay on the internal network). Docker
    carries an inbound connection from outside with a DNAT rule on the host (the `nat` table's
    `DOCKER` chain), so the node sees each peer's own address, which its peer list, the network page
    and its ban logic (`setban`, misbehaviour scores) depend on. Docker's userland proxy, which would
    show every peer as the bridge gateway (`172.31.251.1`), only carries connections made from the
    host itself to the published port; no `[::]` binding is made, so no IPv6 connection can come in
    through it either (the VPC has no IPv6 anyway). The port is published on the node's `edge`
    endpoint, as the proxy's 80 and 443 are (`backend` is internal);
  - **the ingress rule:** the security group opens the port to `p2p_ingress_cidrs`; the module
    refuses `p2p_inbound` with an empty list.

  The node advertises the host's Elastic IP: seedctl gives every node, the explorer's too,
  `-externalip=<the host's address>` (`seed.env` `EXTERNAL_IP`) with `-port`, and an explicit
  `-externalip` turns `-discover` off (ycash6 `src/init.cpp`), so the node never advertises its
  container address; peers learn `<Elastic IP>:<port>` through address gossip. A node can also name
  the explorer directly (`addnode=<explorer hostname>:<port>`).

  **What it exposes.** A third public port on an internet-facing host: a full P2P listener, open to
  anyone in `p2p_ingress_cidrs`, beside 80 and 443. The node holds no wallet (`-disablewallet`), so
  no keys or funds are behind it; its memory is capped by `node_mem_limit_mb` (2304 MiB by default,
  "Host size"), so a peer flood cannot take RAM from PostgreSQL or the proxy beyond the budget. It can
  still hurt: the node may swap (its swap allowance) on the volume PostgreSQL shares before its
  cgroup kills it, and a flood that gets it killed can repeat after the restart, leaving the
  explorer stale for as long as it lasts. Inbound peers can also fill the inbound slots and the
  address book with their own nodes; the outbound connections to the seeds keep the node on the
  chain, but the public peers page then lists what they chose to show; `-maxconnections` (the root's
  `extra_args`) caps its sockets: 8 of them are its own outbound connections, the rest inbound, and
  each peer may hold up to its receive (5 MB) and send (1 MB) buffers, so allow about 6 MB per
  connection in the node's limit. It is a node like the seeds, on the same code, with the same
  exposure as theirs. **Peers' addresses become public:** Inzyght's peers API and the network page
  show the node's peers, so every node that connects to the explorer has its IP address and port
  listed on a public web page; say so to whoever is asked to peer with it.
- **seedctl:** `apply`, `reset`, `stop`, `sync` and `boot` act on all four containers; `reset` also
  deletes the index (it belongs to the old chain) and keeps the secrets and the certificate;
  `status` adds an `explorer` field: the three containers' state and health, Inzyght's image, the
  height Inzyght has indexed (from its database), `httpOnHost` (the HTTP status of
  `/api/v1/version` through the proxy on the host, for `hostname`, which checks the certificate)
  and `httpPublic` (the same through the public name: DNS, the address, the security group). A
  config without `explorer` renders exactly as before. For all four containers (the node too)
  `restarts` (Docker's `RestartCount`: restarts by the restart policy since the container was
  created; an apply that recreates it starts again at 0) and `oomKilled` (Docker's
  `State.OOMKilled`, about the container's last exit), each `null` for a container that is absent;
  the node's `nodeStartedAt` (when its current process started), `nodeOomKills` and
  `nodeOomKillsSinceBoot`: the kernel log's OOM kills of a `ycashd` process, as
  `{"cgroup": N, "host": N}` (`cgroup`: "Memory cgroup out of memory", the container's own limit;
  `host`: "Out of memory", the whole host), `nodeOomKills` from a minute before the current start
  on (so the kill that caused this start counts and one from an earlier start does not),
  `nodeOomKillsSinceBoot` since the host booted; `null` when the kernel log cannot be read (or, for
  `nodeOomKills`, its times or the start time are unknown). The kernel log is the source to trust:
  for the first explorer run's cgroup kill Docker's `OOMKilled` read `false` (and the exit code 0).
  The explorer field's `phase` is one line for a first start: a detached run's current step,
  `prefix import: H of L (N %)`, `explorer image missing: <why>`, `indexing: H of B`, or `serving`;
  a node that restarted during the import adds `, node restarted K times (OOM: …)`: `yes` for a
  cgroup kill in `nodeOomKills` (or Docker's flag set), `yes, the host ran out of memory` for a
  host-wide one, `no`, or `unknown` without a readable kernel log; so a crash loop or a memory kill
  shows from `status` alone. A node restart during the import resumes from its last chainstate
  flush, not from the height it had reached (the network's `-dbcache` sets how often it flushes).
  Example, during the import:
  `{"phase":"prefix import: 305248 of 510247 (59 %), node restarted 1 time (OOM: yes)", …, "inzyght":"absent", …, "restarts":{"ycashd":1,"postgres":0,"inzyght":null,"proxy":0}, "oomKilled":{"ycashd":false,"postgres":false,"inzyght":null,"proxy":false}, "nodeStartedAt":"2026-11-14T10:23:41.5Z", "nodeOomKills":{"cgroup":1,"host":0}, "nodeOomKillsSinceBoot":{"cgroup":1,"host":0}}`.
- **The certificate contact** (`explorer_acme_email`, optional) is not a secret but is kept out of
  sight: a sensitive variable, so no plan line and no output prints it; it is in the Terraform state
  (`network_configs`, as every output value is), in the SSM Run Command parameters of each
  `seedctl apply` (readable by whoever may read the account's Run Command history), on the host in
  the network's `desired.json` / `applied.json` (0600) and its Caddyfile (0640, root and Caddy's
  group), and with Let's Encrypt.

**The Inzyght image.** Inzyght has no licence file, so its image is not published to any
registry. Two modes, exactly one per explorer:

- `build = { repo, commit, jobs }` (now; needs BuildKit, which seedctl installs as `docker-buildx`): the host builds
  [`images/inzyght/Dockerfile`](../../images/inzyght/Dockerfile) itself, with `INZYGHT_REPO=repo`
  and `INZYGHT_COMMIT=commit` (a full SHA, which the Dockerfile checks after the clone; its
  dependencies are cloned at pinned commits and the compile runs with no network). The
  Dockerfile and `entrypoint.sh` come from this module's own revision: they reach the host in the
  `host_files` output with seedctl, and the network's config carries their sha256, which seedctl
  checks before it builds. The image is tagged `ycash-local/inzyght:<commit12>-<context12>`, never
  pulled (`pull_policy: never`), and built again only when the commit or the build files change.
  The checked context is kept on the data volume, so a new instance rebuilds the image at boot
  (after starting the node, PostgreSQL and the proxy). After each build BuildKit's cache is pruned
  and every other `ycash-local/inzyght` tag removed. `docker-buildx` is installed on the first
  build, waiting up to ten minutes for the dpkg lock (apt-daily on a new instance) and retried.
  **A build that fails never keeps the node down:** the node, PostgreSQL and the proxy start
  without the Inzyght service (the proxy answers its 503 page), `apply` then fails naming the
  reason, `status` shows `imageMissing` with it, and the next `apply` (a deploy) builds again.
- `image = "<repository>@sha256:<digest>"` (later, once a licence allows a published image):
  pulled like every other image.

**Host size.** Built natively in a container limited to 2 CPUs and 3 GB (arm64, 2026-11-14):
configure 30 s, compile 1 min 58 s with 2 jobs, the largest compiler process 0.95 GB resident, so
about 2 GB with `jobs = 2`. A `t3a.medium` (2 vCPU, 4 GiB) builds it before the node starts on the
first deploy (expect 5 to 15 minutes on its slower cores) and runs the four services (E1, steady:
node 0.4-0.9 GB, PostgreSQL 0.2-0.3 GB, Inzyght under 50 MB, Caddy 20 MB).

The memory budget on a 4 GiB host with the 4 GiB swap file (MiB; the kernel and the OS keep about
300 of the 4096), with the module's defaults:

| Container | `mem_limit` | swap allowed beyond it | RAM + swap at most |
|---|---|---|---|
| node | `node_mem_limit_mb` 2304 | 2048 (`memswap_limit` set explicitly) | 4352 |
| PostgreSQL | 768 | 768 (Docker's default) | 1536 |
| Inzyght | `mem_limit_mb` 768 | 768 (Docker's default) | 1536 |
| proxy | 128 | 128 (Docker's default) | 256 |
| together | 3968 (3200 during the prefix import, when Inzyght does not run) | 3712 | 7680 of the host's 8192 |

Inzyght uses under 50 MB, so a host may set `mem_limit_mb = 256` (the lowest the module accepts):
then the limits add up to 3456 (3200 during the import), the swap allowances to 3200, RAM plus swap
at most to 6656.

**Why the node's limit is 2304 MiB.** The first explorer run gave the node 1536 MiB (with
`-dbcache=512`), and 36 minutes into the prefix import (`-loadblock` with `-txindex
-insightexplorer`) the kernel killed it: the kernel log shows a cgroup OOM kill
(`constraint=CONSTRAINT_MEMCG`, "Memory cgroup out of memory: Killed process … (ycashd)") with
about 1.5 GiB resident (`anon-rss` 1,549,184 kB), invoked from the import thread. Docker restarted
it; afterwards `docker inspect` showed `RestartCount` 1, `OOMKilled` false and exit code 0, so
Docker's own flag did not record the kill (hence `status` reads the kernel log). The node resumed
from its last chainstate flush, well below the height it had reached. The fix relies on the higher
limit: 2304 MiB of RAM, and `-dbcache=256` in the explorer root, which keeps the coins cache smaller
and makes it flush more often, so a restart loses less.

How the limits act (Docker, cgroup v2): a compose `mem_limit` without `memswap_limit` gets Docker's
`--memory-swap` default of twice `--memory`, and the node's `memswap_limit` is set explicitly (the
limit + 2048), so its swap allowance does not move with `node_mem_limit_mb`. A swap allowance only
permits the kernel to swap the container's pages out before it kills a process in it, where swap is
on and the kernel accounts swap for the cgroup; it does not guarantee it. The first run's kill came
at the RAM limit with the node's resident memory at the limit, so swap did not save it there: the
module creates the swap file (`setup.sh`, `swap_mb`) but sets no `vm.swappiness` and does not check
that swap is on or what the container's `memory.swap.max` is, and that host's swap state at the time
was not recorded. Read `swapon --show` and the container's `memory.swap.max` and `memory.swap.current`
on the host before counting on the swap allowance. The limits together (3968 with the defaults)
exceed the RAM the OS leaves (about 3.8 GiB), deliberately: the steady use is far below them; RAM
plus every swap allowance (7680) stays under the host's 8192.
Keep the module's 4 GiB swap for a rebuild while the node runs, and `cpu_credits = "unlimited"` for
the first deploy (build, prefix import, first index). A `t3a.small` (2 GiB) would need `jobs = 1`
and the swap for the build and leaves the node and PostgreSQL little page cache; it is not
recommended. Disk for yb-fast: about 2.5 GB of node data, 1 GB of PostgreSQL, 1.1 GB of framed
prefix while it imports and 1.1 GB of prefix cache: 40 GiB is ample. The root volume holds the OS,
the swap file, the images and the build: give an explorer host `root_volume_size = 30` (the
default 20 GiB is tight with a 4 GiB swap file and a rebuild beside the running image).

### Value pools (`explorer.pools`, default none)

An explorer may also serve the value-pools page under `/pools/`: how much YEC sits in each pool of
the chain, now and over time, from the node's value-pool index (it needs a node image of
6.22.0-beta3 or later). It is our own small service
([`images/value-pools`](../../images/value-pools/README.md)), not part of Inzyght.

```hcl
      explorer = {
        # ...
        pools = {
          image = "ghcr.io/<owner>/ycash-value-pools@sha256:..."   # value-pools-image.yml
          title = "Ycash fast testnet"                              # the page's heading (optional)
          # mem_limit_mb = 128
        }
      }
```

What it adds, and only when set (without it every rendered file and the network's config are what
they were before the option):

- **`pools-<key>`**: uid 2007, read-only root, no capabilities, `mem_limit_mb` (128; it uses about
  25 MiB), on `backend` only at the fixed address .13, no published port. Like Inzyght it starts
  once the prefix is imported.
- **The node's RPC** admits a second address: `YCASHD_RPC_ALLOWIP` becomes Inzyght's .12 and the
  service's .13. The service sends only `getblockchaininfo`, `getblockhash` and `getblock`. Its copy
  of the node's credential is `/srv/ycash-data/<key>/explorer/pools.env` (0400, root), beside
  Inzyght's.
- **The proxy** sends `/pools` and everything under it to the service; every other path goes to
  Inzyght as before. No new port, no new security-group rule, no new host file.
- **Its samples** are in `/srv/ycash-data/<key>/explorer/pools/` (one small file). A `reset` deletes
  the file with the chain; removing the option removes the container and leaves the file.
- **First start:** about 2,600 `getblock` calls over two to three minutes on yb-fast, one at a time
  with a pause between them, then one or two calls per new block (the image's README, "History").
- `seedctl status <key>` gains `explorer.pools`, the container's state.

**Turn it on:** run `value-pools-image.yml`, put the printed digest in `explorer.pools.image` in the
explorer's root, deploy. **Verify:** `https://<the explorer's name>/pools/` shows the totals, and
`/pools/api/v1/status` says `historyComplete: true` a few minutes later with `rpcErrors: 0`.
**Roll back:** remove `pools` and deploy; the node's RPC allow list, the Caddyfile and the compose
file return to what they were.

## The lightwallet (a network's `lightwallet`)

The same module, called from a fourth root with its own state, makes a **lightwallet host**: one
machine that runs a public light-wallet server for the mobile app and the web wallet beside a node
of its own, at one public HTTPS name: lightwalletd-dd (`--yellowback`, the lightwalletd
repository's own image, published by `.github/workflows/lightwalletd-image.yml`), a gRPC-web proxy
(Envoy, as the Kubernetes chart's gateway and yew's web plan use) and a TLS proxy (Caddy, as the
explorer's). Like the pool and explorer hosts it is never a seed: its own address, state, deploy
layer and role.

```hcl
module "lightwallet" {   # e.g. the operator's testnet-lightwallet/nodes root, one host, fast only
  source            = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds             = data.terraform_remote_state.ips.outputs.seeds    # its own ips root, one address
  name_prefix       = "testnet-lightwallet"
  vpc_cidr          = "10.80.0.0/16"
  instance_type     = "t3a.medium"
  data_volume_size  = 30
  p2p_ingress_cidrs = []                       # nothing published for P2P: the node only connects out
  networks = {
    yb-fast = {
      profile    = "fast"
      extra_args = "-listen=0 -addnode=<the network's seed name>:18833"
      insight    = true                        # -txindex -insightexplorer, before the first import
      lightwallet = {
        hostname      = "<the server's name>"  # its A record points at the host's address
        image         = "ghcr.io/<owner>/lightwalletd@sha256:..."   # lightwalletd-image.yml
        grpcweb_image = "envoyproxy/envoy:v1.40.2@sha256:..."
        proxy_image   = "caddy:2.10-alpine@sha256:..."
        grpcweb_origins = ["https://<the web wallet's origin>"]   # CORS: each origin by name; required, never "*"
        # mem_limit_mb      = 768              # lightwalletd
        # node_mem_limit_mb = 2304             # the node container ("Host size" of the explorer)
      }
    }
  }
  lightwallet_acme_email = var.acme_email      # optional certificate contact; from a secret, never committed
  prefix = { ... }                             # the same testnet-prefix-v1 pin as the seeds
}
```

What a `lightwallet` adds, per host (`files/seedctl-lightwallet`, seedctl's lightwallet half):

| Container | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| `ycashd-<key>` | the network's node image | uid 2001, read-only root, no capabilities | `backend` (.11), `edge` | `YCASHD_INSIGHT=1` (`-txindex -insightexplorer -experimentalfeatures`: lightwalletd's `GetAddressUtxos` / `GetTaddressTxids` read the address index); RPC bound to its `backend` address (.11) and loopback only, never `0.0.0.0` (`rpcbind` in its `ycash.conf`, `-rpcbind=127.0.0.1` on its command line; ycashd binds both), allowed for lightwalletd's fixed address only (`172.31.252.12`; and loopback, for `seedctl`'s `docker exec`); `-disablewallet`; no published port; P2P out through `edge`; `node_mem_limit_mb` (2304 MiB) plus 2 GiB of swap, `-dbcache=256` in the root, the explorer's lesson ("Host size" above) |
| `lightwalletd-<key>` | `lightwallet.image` (by digest) | uid 2002, read-only root, no capabilities, `mem_limit_mb` (768) | `backend` only (.12) | plain gRPC on 9067 (`--no-tls-very-insecure`: TLS ends at the proxy), `--yellowback`; the node's credential in its own 0400 file (`/srv/ycash-data/<key>/lightwallet/lightwalletd.conf`, mounted read-only; never an environment variable or an argument); its block cache in `lightwallet/cache` on the data volume (a reset deletes it with the chain); `--trusted-proxy-cidr` the gRPC-web proxy's address only, so its per-peer Yellowback limiter counts each client by the address the TLS proxy saw; started once the prefix is imported; healthcheck `lwdinfo` (GetLightdInfo) |
| `grpcweb-<key>` | `lightwallet.grpcweb_image` (Envoy, by digest) | uid 2007, read-only root, no capabilities, 128 MiB | `backend` only (.13) | h2c on 8080 from the TLS proxy; the `grpc_web` filter (a browser's `application/grpc-web` request in, gRPC to lightwalletd; native gRPC passes through untouched), CORS for `grpcweb_origins` only, each matched exactly (`POST`, `OPTIONS`; the request headers `content-type`, `x-grpc-web`, `x-user-agent` and `grpc-timeout`, which is what a gRPC-web client sends: yew's web client sends the first two; the `grpc-status` / `grpc-message` headers exposed), routes for `cash.z.wallet.sdk.rpc.CompactTxStreamer` and `YellowbackStreamer` only (any other path 404); no admin interface; no request timeout (block ranges, the mempool stream) |
| `lwproxy-<key>` | `lightwallet.proxy_image` (Caddy, by digest) | uid 2006, every capability dropped but binding low ports, read-only root, 128 MiB | `backend` (.10), `edge` | the only published ports, TCP 80 and 443 (HTTP/3 off); Let's Encrypt certificate for `hostname` (HTTP-01), renewal, redirect to HTTPS, HSTS; HTTP/1.1 and HTTP/2, every request streamed (`flush_interval -1`) over h2c to the gRPC-web proxy with `X-Real-IP` set to the client's address (a client's own header is replaced); a 4 MB request limit (gRPC's); certificate in `lightwallet/caddy` (kept across resets and new instances); a plain 503 while the backend is not up |

- **One name, one port, both protocols.** The apps call `<hostname>:443` with native gRPC over
  TLS (HTTP/2); the web wallet calls `https://<hostname>` with gRPC-web (`fetch`, HTTP/1.1 or 2).
  Both go through the TLS proxy and the gRPC-web proxy to lightwalletd. The web wallet's page is
  served elsewhere (its own origin), so it reaches this server across origins: CORS on the gRPC-web
  proxy answers its preflight for the origins `grpcweb_origins` names (no wildcard: a page from any
  other origin is refused by the browser), and its content security policy must name this server
  (`connect-src`). With `tls = false` (a test without a name) the proxy listens on port 80 only,
  with h2c for native gRPC.
- **Networks.** `backend` (`172.31.252.0/24`; .10 the TLS proxy, .11 the node, .12 lightwalletd, .13
  the gRPC-web proxy, every other container from `.128/25`) is internal: no route out, so neither
  lightwalletd nor Envoy can reach anything but each other and the node. `edge`
  (`172.31.253.0/24`) carries the node's outbound P2P and the TLS proxy's ports. A `DOCKER-USER`
  rule refuses both subnets the metadata address (as the explorer's, and with the same reasoning
  for the boot window).
- **lightwalletd holds the node's full RPC credential**: the node has no wallet, so there are no keys
  or funds behind it, but a compromised lightwalletd could stop or disconnect this host's own node;
  it cannot reach another host's (each has its own credential). lightwalletd is the only RPC client
  the node admits besides `seedctl` on the host.
- **Inbound:** 443 and 80 to `lightwallet_ingress_cidrs` (default everyone). Nothing else: the
  node publishes no P2P port (it only connects out), so the security group opens none for it.
- **The prefix.** The node bootstraps from the network's prefix like every other node here; while
  it imports, only the node and the two proxies run (the proxy answers 503), and `prefix-check`
  starts lightwalletd once the import is done. lightwalletd then fills its block cache from the
  node (from Sapling's activation) and serves meanwhile.
- **seedctl:** `apply`, `reset`, `stop`, `sync` and `boot` act on all four containers; `reset` also
  deletes lightwalletd's block cache with the chain (its configuration, the node's credential and
  the certificate stay). `status` adds a `lightwallet` field:

  | Field | What it says |
  |---|---|
  | `phase` | `deploying: <step>` (a detached run), `prefix import: H of L (N %)`, `prefix imported …`, `lightwalletd is not running`, `lightwalletd is starting (no GetLightdInfo yet)`, `lightwalletd is catching up: H of B`, `the node is catching up: B of H headers`, `the node has no peers …`, `serving`, or `starting (the TLS proxy answers …)`. `serving` = lightwalletd at the node's tip, the node within one block of the headers its peers announced and at least one peer, and both protocols answering through the proxy on the host. The limit: if every peer of the node is behind as well, nothing on the host can tell |
  | `url`, `grpc` | the gRPC-web URL and the native gRPC endpoint (`host:443`) |
  | `lightwalletd`, `grpcweb`, `lwproxy` | each container's state (and lightwalletd's health) |
  | `height`, `getLightdInfo` | lightwalletd's latest cached block, and its `GetLightdInfo` (version, vendor, chain, block height, Sapling activation, branch id), read inside its container with `lwdinfo` |
  | `node` | the node's own `blocks`, `headers` (`getblockchaininfo`) and `connections` (`getconnectioncount`) |
  | `grpcOnHost`, `grpcWebOnHost` | a `GetLightdInfo` through the TLS proxy on this host, for its name, as native gRPC and as gRPC-web: the call's `grpc-status` (`"0"` answered), else `http <code>`, else `none` |
  | `grpcPublic`, `grpcWebPublic` | the same through the public name (DNS, the Elastic IP, the security group, the certificate) |
  | `restarts`, `oomKilled`, `nodeStartedAt`, `nodeOomKills`, `nodeOomKillsSinceBoot` | as the explorer's |
- **The Yellowback service** (`YellowbackStreamer`) starts only where the node serves `yed_*` (the
  vault upgrade and an attestor set for the network); without them lightwalletd serves
  `CompactTxStreamer` alone and logs "Yellowback service not started", and its calls
  (`GetChainInfo` among them) answer `Unimplemented`. That is the fast testnet's case in beta2 and beta3 (it
  has no attestor set), and not a fault: `status` and its probes check `GetLightdInfo` only, so a
  server without the Yellowback service still reads `serving`.
- **The certificate contact** (`lightwallet_acme_email`, optional) is handled as the explorer's
  (sensitive in the module, root-only on the host).

## The x402 host (a network's `x402`)

The same module, called from a fifth root with its own state, makes an **x402 host**: one small
machine that runs the fast testnet's x402 demonstration at one public HTTPS name (workspace
`docs/plans/x402-demonstrations.md` §3.2, decisions D-2, D-4, D-6 and D-10): a paid chain-data API
that agents pay per request in testnet YEC, the x402 facilitator that checks and relays their
payments, and the testnet faucet that gives visitors their first coins. Like the pool, explorer and
lightwallet hosts it is never a seed: its own address, state, deploy layer and role. What an attacker
gains from it and the limits that answer each abuse: [`docs/x402-host-threats.md`](../../docs/x402-host-threats.md).

```hcl
module "x402" {   # e.g. the operator's testnet-x402/nodes root, one host, fast only
  source            = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds             = data.terraform_remote_state.ips.outputs.seeds    # its own ips root, one address
  name_prefix       = "testnet-x402"
  vpc_cidr          = "10.81.0.0/16"
  instance_type     = "t3a.small"
  data_volume_size  = 20
  swap_mb           = 4096
  p2p_ingress_cidrs = []                       # nothing published for P2P: the node only connects out
  extra_args        = "-dbcache=128 -maxconnections=16"
  networks = {
    yb-fast = {
      profile    = "fast"
      extra_args = "-listen=0 -addnode=<seed address>:18833 ..."   # fixed outbound peers, by address
      insight    = true                        # -txindex -insightexplorer: the API's address reports
      x402 = {
        hostname          = "<the host's name>"   # its A record points at the host's address
        api_image         = "ghcr.io/<owner>/x402-ycash-chain-api@sha256:..."
        facilitator_image = "ghcr.io/<owner>/x402-ycash-facilitator@sha256:..."
        faucet_image      = "ghcr.io/<owner>/ycash-faucet@sha256:..."       # faucet-image.yml
        proxy_image       = "caddy:2.10-alpine@sha256:..."
        explorer_url      = "https://<the explorer's name>"
        lightwalletd      = "<the light-wallet server>:443"                  # shown on the API's page
        # price_exact_zat = 10000, price_broadcast_zat = 10000, zero_conf_cap_zat = 100000   (D-10)
        # faucet = { amount_zat = 10000000, daily_cap_zat = 1000000000, pow_bits = 16, ... }
        shielded = { price_zat = 10000, confirmations = -1 }   # the private routes (below); omit for none
      }
    }
  }
  x402_acme_email = var.acme_email             # optional certificate contact; from a secret, never committed
  prefix = { ... }                             # the same testnet-prefix-v1 pin as the seeds
}
```

What an `x402` adds, per host (`files/seedctl-x402`, seedctl's x402 half):

| Container | Image | Runs as | Networks | Notes |
|---|---|---|---|---|
| `ycashd-<key>` | the network's node image | uid 2001, read-only root, no capabilities | `backend` (.11), `edge` | `YCASHD_INSIGHT=1`; **keeps its wallet** (no `-disablewallet`): the faucet's, the host's only spending key, in the datadir on the encrypted data volume; `-exportdir` for `seedctl x402-backup`, `-rpcthreads=8 -rpcworkqueue=64` (three RPC clients); RPC bound to its `backend` address and loopback only, allowed for the API's, the facilitator's and the faucet's fixed addresses (`172.31.254.12`–`.14`) and loopback, never the proxy; no published port; P2P out through `edge`; `node_mem_limit_mb` (1536 MiB) plus 2 GiB of swap |
| `facilitator-<key>` | `x402.facilitator_image` (x402-ycash `packages/facilitator`) | uid 2009, read-only root, no capabilities, 192 MiB | `backend` only (.13) | port 4022, reachable from the API only; `/verify` and `/settle` need the API key (`apiKey`); its configuration in a 0400 file of its uid (`x402/facilitator.json`: the node's RPC credential, the API key, `ycash:testnet`, `testnetProfile` = the network's profile (D-6: it refuses to start on another testnet), mempool settlement allowed (confirmations −1 to 1)); its settlement and channel stores in `x402/facilitator` (one claim per settled txid, so one payment buys one request); holds no spending key; healthcheck `/healthz` |
| `x402api-<key>` | `x402.api_image` (x402-ycash `examples/chain-api`) | uid 2008, read-only root, no capabilities, 256 MiB | `backend` only (.12) | port 4021; the paid routes (`/v1/address`, `/v1/tx`, `/v1/block`, `/v1/chain`, `/v1/yellowback` at `price_exact_zat`; `POST /v1/broadcast`, the paid relay, at `price_broadcast_zat`; mempool settlement up to `zero_conf_cap_zat`) and the free `/`, `/pricing`, `/healthz`; `API_PAY_TO` = the faucet wallet's P2PKH address; the node's credential and the API key in its 0400 environment file (`x402/api.env`); its own per-client limits (`paid_per_minute`, `unpaid_per_minute`, `free_per_minute`), counting the address the proxy writes (`API_TRUST_PROXY=1`); no state of its own; healthcheck `/healthz` |
| `faucet-<key>` | `x402.faucet_image` (`images/faucet`, `FAUCET_MODE=testnet`) | uid 2010, read-only root, no capabilities, 96 MiB | `backend` only (.14) | pays `faucet.amount_zat` from the wallet's Sapling address; per client address and per recipient (`per_ip`, `per_address` per `window_seconds`), `daily_cap_zat` in any 24 h, `pow_bits` of proof of work, one payment at a time; refuses unless the node reports this testnet profile; sweeps `payTo` back into its Sapling address (`SWEEP_FROM`, at `sweep_min_zat`; only coins two blocks deep, one deeper than any settle waits for, `SWEEP_MIN_CONF`; never dust below 5,000 zat; a sweep that would not cover its fee is skipped); its `/metrics` is not routed; healthcheck `/info` |
| `x402proxy-<key>` | `x402.proxy_image` (Caddy, by digest) | uid 2006, every capability dropped but binding low ports, read-only root, 128 MiB | `backend` (.10), `edge` (.10) | **the only published port, TCP 443** (80 with `tls = false`); the Let's Encrypt certificate over the TLS-ALPN challenge (no HTTP challenge, no port 80, no redirect), HSTS; HTTP/1.1 and HTTP/2; 64 KB of headers (a payment travels in one), 256 KB of body (the broadcast route's transaction); header, body, write and idle timeouts; the faucet's own paths (`/faucet/`, `info`, `challenge`, `send`, its script) to the faucet, everything else to the API, each with `X-Forwarded-For` set to the client's address (a client's own header is replaced); a 503 while the backend is not up |

- **Networks.** `backend` (`172.31.254.0/24`; .10 the proxy, .11 the node, .12 the API, .13 the
  facilitator, .14 the faucet, every other container from `.128/25`) is internal: no route out, so
  none of the three services can reach anything but each other and the node. `edge`
  (`172.31.255.0/24`) carries the node's outbound P2P and the proxy's port. A `DOCKER-USER` rule
  refuses both subnets the metadata address; another drops a client address's new connections to the
  proxy above `conn_rate_limit` a minute (bursts of twice that; `hashlimit`, per source address).
- **Inbound:** 443 alone to `x402_ingress_cidrs` (default everyone). Nothing else: the node
  publishes no P2P port (it only connects out to fixed peers), and the certificate needs no port 80.
- **The faucet's wallet.** ycashd creates it at the node's first start (a random seed) or, if the
  operator placed a recovery phrase at `/srv/ycash-data/<key>/x402/mnemonic` before that start
  (mode 0400, the node's uid; mounted read-only and passed as `YCASHD_MNEMONIC_FILE`), from that
  phrase. Once the chain is imported seedctl asks it for one transparent address (the API's
  `payTo`; refused if the wallet hands out a post-quantum or script address) and one Sapling address
  (the faucet's source), and keeps both (`x402/payto`, `x402/zaddr`). The wallet lives in the
  datadir on the encrypted data volume: kept across upgrades and instance replacements, and **moved
  aside and back across a reset** (the chain goes, the keys stay; the node rescans). Nothing ever
  deletes a wallet: a kept wallet that cannot return because the datadir already holds one, or a
  keep an interrupted reset left behind, moves to `x402/keep.<UTC timestamp>` and the log says so.
  The two kept addresses are only a record: on every `apply` (and after the import) seedctl checks
  that the node's wallet holds the spending key of both (`validateaddress` / `z_validateaddress`,
  `ismine`; `x402/owned` records the checked pair) and starts the API and the faucet only then. If
  it does not (a different wallet in the datadir), the API and the faucet are stopped and seedctl
  says what to do: put the right wallet back, or delete `x402/payto` and `x402/zaddr` to let this
  wallet make new ones. Backup:
  `seedctl x402-backup <key>` writes a `z_exportwallet` file (the recovery phrase and the keys) into
  the node's export directory on the data volume and prints its path; the operator copies the phrase
  off the host in an interactive SSM session and deletes the file (Run Command output is stored by
  SSM, so the phrase never goes through it). Losing it loses testnet coins only: a new wallet is
  funded again from the pool. Fund the faucet by sending testnet YEC to its Sapling address
  (`status` shows it) and keep its balance to a few days of `daily_cap_zat`: everything in it is
  hot.
- **Generated secret** (`x402/secrets/`, 0700): the facilitator's API key, made on the host at the
  first apply, never leaving it, readable by root and handed to the facilitator and the API only.
  **The facilitator's replay store** (`x402/facilitator`, its `/data`: one claim per settled txid)
  is on the data volume, so it survives restarts, upgrades, resets and new instances. The node's RPC credential is the network's
  (`rpc.env`), in the facilitator's 0400 file and the API's and the faucet's 0400 environment files.
- **The prefix.** While the node imports, only the node and the proxy run (503); `prefix-check`
  makes the faucet's addresses and starts the facilitator, the API and the faucet once the import
  is done, after waiting for the node's RPC (the import's check restarts the node without its
  `-loadblock` flags). A check that could not start them leaves the API out and every later check
  (every 10 minutes) tries again until it is rendered; a deploy (`seedctl apply`) does the same at once.
- **Host size.** A `t3a.small` (2 GiB, 2 vCPU burstable) with a 4 GiB swap file. Steady state, from
  the explorer host's measurements (its node with both indexes 386 MB, 868 MB while indexing): the
  node about 0.4–0.9 GB, the API and the facilitator about 0.1 GB each (Node.js), the faucet 30 MB,
  Caddy 20 MB, the OS and Docker about 0.35 GB: about 1.1–1.6 GB of 1.9. The limits (1536 + 256 +
  192 + 96 + 128 MiB) are caps, not reservations. The prefix import with both indexes peaked at
  about 1.5 GiB resident on the explorer host; here only the node and the proxy run then, and the
  node may use 2 GiB of swap beyond its 1536 MiB, so the import is slower but is not killed. Use
  `cpu_credits = "unlimited"` for the first import, `standard` after. If `status` ever shows the
  node's OOM kills, the next size is `t3a.medium` (an in-place change, a stop and a start).
- **seedctl:** `apply`, `reset`, `stop`, `sync` and `boot` act on all five containers; `reset`
  deletes the chain and keeps the wallet, the addresses, the stores, the secrets and the
  certificate. `x402-backup <key>` as above. `status` adds an `x402` field:

  | Field | What it says |
  |---|---|
  | `phase` | `deploying: <step>`, `prefix import: H of L (N %)`, `prefix imported …`, `a service is not healthy: …`, `the node is catching up: B of H headers`, `the node has no peers …`, `serving`, or `starting (the TLS proxy answers …)`. `serving` = every service healthy, the node within a block of its peers' headers with a peer, and on this host the free route `200` and the paid route `402` with its `PAYMENT-REQUIRED` header |
  | `url` | the public URL |
  | `facilitator`, `api`, `faucet`, `proxy` | each container's state and health |
  | `payTo`, `faucetAddress` | the faucet wallet's transparent address (the API's `payTo`) and Sapling address (the faucet's source; fund it here) |
  | `faucetBalance`, `payToBalance` | the Sapling address's confirmed balance, and what agents paid that is not swept yet (mempool included), YEC |
  | `settlementClaims` | the claims the facilitator holds: one per settled payment, until pruned |
  | `faucetInfo` | the faucet's `/info`: `available`, `tip`, `amountZat`, `powBits` |
  | `freeOnHost`, `paidOnHost`, `freePublic`, `paidPublic` | `GET /pricing` and `GET /v1/address/<payTo>` through the proxy, on this host for its name and through the public name: the status code (`402 payment-required` when the header is there), else `none` |
  | `node`, `restarts`, `oomKilled`, `nodeStartedAt`, `nodeOomKills`, `nodeOomKillsSinceBoot` | as the lightwallet's |
- **The API's interface** (x402-ycash `examples/chain-api/src/config.ts`): the host gives it
  `HOST`, `PORT` (4021), `X402_NETWORK` (`ycash:testnet`), `FACILITATOR_URL`, `FACILITATOR_API_KEY`,
  `API_PAY_TO`, `API_RPC_URL` / `API_RPC_USER` / `API_RPC_PASSWORD` (the node keeps a password, so
  no cookie file), `API_PRICE_ZAT`, `API_PRICE_BROADCAST_ZAT`, `API_ZERO_CONF_CAP_ZAT`,
  `API_PAID_PER_MINUTE`, `API_UNPAID_PER_MINUTE`, `API_FREE_PER_MINUTE`, `API_TRUST_PROXY` (1),
  `API_LINK_FAUCET`, `API_LINK_EXPLORER`, `API_LINK_LIGHTWALLETD`. The facilitator: its JSON file
  (`testnetProfile`, confirmations from −1) and `/data`.
- **The certificate contact** (`x402_acme_email`, optional) is handled as the explorer's.
- **The private routes** (`x402.shielded`, off unless given). The API also sells every read route
  under `/v1/private/…`, paid in shielded YEC with x402-ycash's `sapling-proof` method: each 402
  names a fresh diversified Sapling address and a memo for that one request, the client sends
  shielded YEC there (from a Sapling key and a light-wallet server: x402-ycash `x402-light`), and
  presents the txid; the facilitator finds the note in the node's wallet, checks memo, amount and
  depth, records the payment once and signs a receipt, before the answer (upfront). What the host
  adds:
  - **A base Sapling address of its own** (`x402/zbase`), made by the node's wallet with the other
    two addresses and checked with them (`x402/owned` then holds all three); every private
    request's address is a diversified address of it (`z_getnewdiversifiedaddress`, the API's only
    wallet call besides the startup `z_validateaddress`). What agents pay privately stays on those
    addresses in the faucet's wallet, apart from the faucet's own balance: it is not swept (testnet
    coins; move it by hand with `z_sendmany` if ever wanted).
  - **The receipt key** (`x402/secrets/receipt-key`, 0600, root): 32 random bytes made on the host
    at the first apply with `shielded` (drawn again in the unlikely case they are not a valid
    secp256k1 key), kept across applies, resets and redeploys so receipts stay verifiable; it
    reaches the facilitator in its 0400 `facilitator.json` (`receiptKey`) and nowhere else. Like the
    API key, it is never in a repository, a Terraform variable or a GitHub secret.
  - **The issued-address registry** (`x402/shielded/issued.json`, mounted at `/shielded` in the API
    and the facilitator only): a directory of group 2011, mode 2770 (setgid), which both containers
    join (`group_add`); the API writes an issued request per private 402, the facilitator reads it
    to settle. It keeps every address ever issued (an address is never issued twice).
  - **Configuration.** The facilitator's file gains `receiptKey`, `issuedAddressRegistryPath`,
    `shieldedMethods` (`["sapling-proof"]`) and `saplingNoteWaitMs` (`note_wait_ms`, 30 s: the
    client broadcasts through another node, so its transaction takes a few seconds to reach this
    one). The API's environment gains `API_ISSUED_REGISTRY`, `API_SAPLING_BASE_ADDRESS`,
    `API_SHIELDED_CONFIRMATIONS` (`confirmations`: −1, the mempool, as the transparent routes; at
    most 1, the facilitator's maximum), `API_PRICE_SHIELDED_ZAT` (`price_zat`) and
    `API_SHIELDED_MAX_OUTSTANDING` (`max_outstanding`, 1000: issued requests held at once; each
    unpaid private 402 issues one, so past it new private 402s fail until records expire, about
    75 minutes after issue).
  - **`status`** adds `privateBase` (the base address) and `privateIssued` (addresses issued so
    far). The private routes are not probed: a probe's 402 would issue an address.

## Cost estimate

On-demand prices in us-east-1, as of 2026-10. Other regions are within about 20 percent.

| Item | Per host, per month |
|---|---|
| `t3a.medium` instance (730 h × $0.0376) | $27.45 |
| gp3 storage, 80 GiB data + 20 GiB root (× $0.08) | $8.00 |
| Public IPv4 address (730 h × $0.005, charged for Elastic IPs in use or idle) | $3.65 |
| **Subtotal** | **≈ $39.10** |

- **Two hosts × three networks: ≈ $78/month**, plus data transfer out. The first 100 GB/month per
  account is free, then $0.09/GB. Every new node that syncs from a seed downloads the chain from it.
- CPU credits in `unlimited` mode: a first sync or a reset's import may cost a few cents extra.
- SSM Session Manager and Run Command: no charge. Terraform state in S3: cents.
- With `nodes/` torn down and `ips/` kept, the two idle addresses cost ≈ $7.30/month.
- A pool host (`t3a.small`, 30 GiB data + 20 GiB root, one public IPv4, one network): ≈ $13.70
  instance + $4.00 storage + $3.65 address ≈ **$21/month**, plus data transfer (stratum traffic is
  small: a job per block and a share every few seconds per miner).
- An explorer host (`t3a.medium`, 40 GiB data + 30 GiB root, one public IPv4, one network):
  ≈ $27.45 + $5.60 + $3.65 ≈ **$37/month**, plus data transfer out (pages and API answers; small
  at testnet traffic).
- A lightwallet host (`t3a.medium`, 30 GiB data + 20 GiB root, one public IPv4, one network):
  ≈ $27.45 + $4.00 + $3.65 ≈ **$35/month**, plus data transfer out (compact blocks to every wallet
  that syncs: small at testnet traffic).
- An x402 host (`t3a.small`, 20 GiB data + 20 GiB root, one public IPv4, one network):
  ≈ $13.72 + $3.20 + $3.65 ≈ **$21/month**, plus data transfer out (JSON answers: small at
  demonstration traffic) and a few cents of surplus CPU credits for the first import.
- A third host adds ≈ $39. An arm64 `t4g.medium` is ≈ $3/month cheaper per host; it needs an
  arm64 image, which the `node-image` workflow does not build today.

## Calling it from a private repository

Two roots, each with its own backend key. The `ref` is a commit SHA of this repository: pin it,
review the diff when bumping it. `nodes/` reads files from elsewhere in this repository
(`charts/ycash-testnet/files/prefix-restore.sh`, `bundles/prefix/import/frame.py`,
`images/inzyght/`). That works because a `git::` source fetches the whole repository at that
commit.

```hcl
# ips/main.tf
terraform {
  backend "s3" {}                      # terraform init -backend-config=backend.hcl (not committed)
}
provider "aws" { region = var.region }
module "ips" {
  source     = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/ips?ref=<sha>"
  seed_count = 2
}
output "seeds" { value = module.ips.seeds }
```

```hcl
# nodes/main.tf
terraform {
  backend "s3" {}
}
provider "aws" { region = var.region }
data "terraform_remote_state" "ips" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "testnet-seeds/ips.tfstate", region = var.region }
}
module "nodes" {
  source             = "git::https://github.com/<owner>/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds              = data.terraform_remote_state.ips.outputs.seeds
  availability_zones = ["<region>a", "<region>b"]
  image              = "ghcr.io/<owner>/ycashd@sha256:<digest>"
  # networks: the default is the three testnets
  prefix = {}   # bootstrap on; each profile's prefix from the chart's values files
}
output "network_configs" {
  value     = module.nodes.network_configs
  sensitive = true
}
output "all_networks_config" {
  value     = module.nodes.all_networks_config
  sensitive = true
}
output "seedctl" { value = module.nodes.seedctl }
output "host_files" { value = module.nodes.host_files } # required from this module revision on: the prefix tools travel in it
output "instance_ids" {
  value     = module.nodes.instance_ids
  sensitive = true
}
```

Then, per host, through SSM (what the private workflow does):

```bash
aws ssm send-command --document-name AWS-RunShellScript --instance-ids <id> \
  --parameters commands='["echo <seedctl output> | base64 -d | gunzip > /usr/local/sbin/seedctl", "chmod 755 /usr/local/sbin/seedctl", "echo <host_files output> | base64 -d | gunzip > /opt/ycash-seed/host-files.json", "seedctl install-files /opt/ycash-seed/host-files.json", "seedctl apply yb-fast <network_configs.yb-fast>"]'
```

(`host_files` is empty when there is nothing to install: no prefix and no explorer. SSM Run
Command caps a command document at 64 KB: with an explorer, seedctl alone is about 10 KB and
`host_files` about 29 KB, so a workflow is best off sending `install-files` as a command of its
own before the run, and splitting `host_files` per file if one command would come near the
limit.)

**Bumping a root to this module revision.** Before it, the prefix tools were in user_data; from
it they come only in `host_files`. A root that bumps must, in the same change, add
`output "host_files" { value = module.nodes.host_files }` and mark `network_configs` and
`all_networks_config` sensitive (the module now does), and its workflow must install
`host_files` before every run. Running hosts keep the tools their user_data wrote, so nothing
breaks at once; without the output, the first replaced instance's reset or new network would fail
(seedctl now says so at once).

A bump that changes the instances' tags (a new `Name`, or any tag the module sets on
`aws_instance`) fails `apply` on hosts that already run: the deploy roles' policy (ycash-ops
`docs/aws-setup.md` §5c) has `DenyInstanceRetag`, which refuses `ec2:CreateTags` and
`ec2:DeleteTags` on an existing instance, and the in-place tag update ends in
`UnauthorizedOperation`. Read the plan before applying: if it updates an instance's tags in place,
either replace that instance (`-replace='module.nodes.aws_instance.seed["<host>"]'`: a new
instance, tagged at creation, which the Deny allows; the data volume and the address stay, and
`seedctl boot` restarts its networks), or have the Yellowback lead architect lift that one Deny
statement by hand for that apply and put it back right after (the backup and restore lines of
§5c's steps 3 and 4).

`ips/example.tfvars` and `nodes/example.tfvars` list every variable with fake values, and
`variables.tf` documents each one. Neither directory has a provider block or a backend, so the
caller chooses the account, the region and the state location. Each directory's `versions.tf`
shows a backend example as comments. The provider is pinned exactly (`hashicorp/aws` 6.70.0);
the caller's `.terraform.lock.hcl` records its hashes.

The node image must be pullable without credentials. The `node-image` workflow pushes to
`ghcr.io/<owner>/ycashd`, and that package must be set to public once, in its package settings.

A mainnet stack is the same two modules in a second pair of roots, with `networks = { main = {
profile = "main" } }`, no `prefix`, its own state and addresses, and its own AWS account.

## Checks

`make seeds-validate`, also run in CI's `eks` job, does five things, offline, with no AWS
credentials and no plan:
- `terraform fmt -check` on both directories;
- `terraform validate` on both directories;
- `terraform test` on `nodes/` (`tests/render.tftest.hcl`): against a mocked AWS provider it
  checks the three testnets by default (ports, magics, profile arguments, peers), that the
  security group opens exactly the enabled networks' ports, per-network images and arguments,
  the `main` profile, that user_data carries no network config (so a network change replaces no
  instance) and fits EC2's 16 KB limit, IMDSv2, encryption, the pool host, the explorer host (its
  config, 443 and 80 only, the host files with the build context), that a network without the new
  options has no new key in its config, and the refusals (`main` beside a testnet, two networks on
  one profile, an image without a digest, an explorer without `insight`, beside a pool, with both
  an image and a build, at `DEBUG`); the lightwallet host (its config, 443 and 80 only and no P2P,
  the host files, the `lightwallets` output without the contact; plain HTTP and listed origins) and
  its refusals (without `insight`, a placeholder all-zero digest, an origin with a path, beside an
  explorer or a pool); the x402 host (its config with the D-10 prices and the faucet's limits, the
  node keeping its wallet, 443 alone and no P2P, the host files, the `x402s` output without the
  contact; plain HTTP on 80 alone; a partly given faucet) and its refusals (without `insight`, a
  placeholder digest, an image by tag, a daily cap below one payment, beside a lightwallet, on
  mainnet);
- `shellcheck` on the host's scripts;
- `tests/seedctl.sh`: `seedctl` against a fake `docker` in a scratch root: apply with the shared
  prefix cache, the rendered arguments and ports, prefix-check, status, a reset and an upgrade of
  one network leaving the other untouched, sync, boot, and its refusals (an image by tag, another
  network's config, a bad name, an injected line); a pool; an explorer: install-files, the node on
  the explorer's networks with its indexes, PostgreSQL and the proxy during the import, Inzyght
  built from the checked context and started with ZMQ after it, private secrets, the Caddyfile
  and config modes, the metadata rule, the build cache and stale tags cleaned, status and its
  phase, a failed build (node and proxy up without Inzyght, `docker-buildx` installed with the
  lock wait, the reason in apply and status, recovery on the next apply), boot on a new instance
  (the node first, then the rebuild from the data volume), reset (index gone, certificate kept),
  its refusals, and its removal; `install-files`' allow-list; `detach` (the job, its phase and
  result in status); a detached run holding the lock (status at once with its phase,
  `install-files` and a second `detach` refused at once, naming it); status before the first
  `applied.json` (the job, `interrupted` after a reboot); a lightwallet: the node on its networks
  with RPC for lightwalletd's address only, the two proxies during the import and lightwalletd
  after it (trusting the gRPC-web proxy only), the node's credential only in lightwalletd's 0400
  file, the Caddyfile and Envoy's routes and origins, the metadata rule, status (GetLightdInfo, the
  height, the four probes, each phase), reset (cache gone, certificate kept), plain HTTP, its
  refusals and its removal; an x402 host: the node on its networks with its wallet and RPC for the
  three services only, the proxy alone on 443 during the import, the facilitator's 0400 file with
  the credential and the API key, the generated secrets, the metadata rule and the per-address
  connection limit, the faucet's addresses after the import, the three services on the internal
  network with their environments, status (serving, balances, both routes), reset (the wallet back
  after the bootstrap), `x402-backup`, a placed recovery phrase, plain HTTP, its refusals (a
  post-quantum `payTo` among them) and its removal; and a host without the prefix tools (refused at
  once).
