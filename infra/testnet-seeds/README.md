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
applies (`network_configs`: image, ports, arguments, peers, prefix) and `seedctl` itself
(`seedctl`, gzip + base64). The operator's deploy workflow installs that `seedctl` on every
host and runs one command there through **SSM Run Command** (no SSH, no inbound port):

| | Command on each host | What happens | Other networks |
|---|---|---|---|
| deploy | `seedctl apply <net> <config>` (`sync <all>` for every network) | creates the network's directory, its RPC credential, bootstraps an empty datadir from the prefix, pulls the image, starts the container, waits for RPC | untouched |
| upgrade (image) | `seedctl apply <net> <config>`, one host at a time | the container is recreated on the new image with the same data; the next host goes only after this one answers RPC | untouched |
| reset | `seedctl reset <net> <config>` | stops the container, deletes that network's datadir, bootstraps again from the host's verified prefix cache (nothing downloaded twice), starts it | untouched |
| status | `seedctl status [<net>]` | one JSON line per network: container, image, chain, blocks, headers, progress, peers, inbound | n/a |
| stop | `seedctl stop <net>` | stops the container; the data stays | untouched |

`seedctl sync` applies every configured network and stops (never deletes) any network that is no
longer configured. Each host serialises seedctl runs with a lock, so the prefix timer, a boot and
a workflow run never interleave.

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
Zcash-testnet prefix (`testnet-prefix-v1`, shared by all three testnets). The host downloads it
once into `/srv/ycash-data/prefix-cache` with the testnet chart's own `prefix-restore.sh`, which
refuses unless `SHA256SUMS` hashes to the pin and every file checks. Each network then frames it
with its own magic (`bundles/prefix/import/frame.py`, which checks every block again) and imports
it with `-loadblock`; the timer drops the flags and the framed copies once the node reaches
`last_height`. Both scripts come from the same commit of this repository as the module. A refused
bundle stops that network's apply, never another network. The magic must be the one compiled
into the image for that profile; `prefix_magic_overrides` exists only for an image built before
the profiles (its single testnet magic, `fa1af9bf`).

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
- A third host adds ≈ $39. An arm64 `t4g.medium` is ≈ $3/month cheaper per host; it needs an
  arm64 image, which the `node-image` workflow does not build today.

## Calling it from a private repository

Two roots, each with its own backend key. The `ref` is a commit SHA of this repository: pin it,
review the diff when bumping it. `nodes/` reads two scripts from elsewhere in this repository
(`charts/ycash-testnet/files/prefix-restore.sh`, `bundles/prefix/import/frame.py`). That works
because a `git::` source fetches the whole repository at that commit.

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
  prefix = { base_url = "https://…/testnet-prefix-v1", sums_sha256 = "<pin>", last_height = 510247 }
}
output "network_configs" { value = module.nodes.network_configs }
output "all_networks_config" { value = module.nodes.all_networks_config }
output "seedctl" { value = module.nodes.seedctl }
output "instance_ids" {
  value     = module.nodes.instance_ids
  sensitive = true
}
```

Then, per host, through SSM (what the private workflow does):

```bash
aws ssm send-command --document-name AWS-RunShellScript --instance-ids <id> \
  --parameters commands='["echo <seedctl output> | base64 -d | gunzip > /usr/local/sbin/seedctl", "chmod 755 /usr/local/sbin/seedctl", "seedctl apply yb-fast <network_configs.yb-fast>"]'
```

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
  instance) and fits EC2's 16 KB limit, IMDSv2, encryption, and the refusals (`main` beside a
  testnet, two networks on one profile, an image without a digest);
- `shellcheck` on the host's scripts;
- `tests/seedctl.sh`: `seedctl` against a fake `docker` in a scratch root: apply with the shared
  prefix cache, the rendered arguments and ports, prefix-check, status, a reset and an upgrade of
  one network leaving the other untouched, sync, boot, and its refusals (an image by tag, another
  network's config, a bad name, an injected line).
