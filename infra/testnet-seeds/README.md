# infra/testnet-seeds — the Ycash testnet's seed nodes on AWS EC2

## In plain words

A new node joining the Ycash testnet has to find someone to talk to first. The testnet answers
that with **seed nodes**: a few always-on machines whose addresses are written into the node
program itself ("fixed seeds"). Because those addresses are compiled in, they must never change,
however many times the machines behind them are rebuilt.

This directory describes those machines for AWS in two separate pieces:

- **`ips/`, the addresses.** One fixed public address (an Elastic IP) per seed. It is created
  once and kept forever. Terraform refuses to delete one.
- **`nodes/`, the machines.** One small virtual machine per address, each with its own disk for
  the blockchain, running the Ycash node in Docker. They can be torn down and rebuilt as often as
  wanted. The addresses stay.

Nothing here names an AWS account, a person or a storage bucket. The owner's real settings live
in a private repository that uses these pieces by reference ([below](#calling-it-from-a-private-repository)).
Deployment runs from that private repository, never from this one. This repository's CI only
checks that the Terraform here is well formed.

The machines hold no keys and no coins. A seed's only secret is its own RPC password, which is
made on the machine and never leaves it.

## The two layers

| Layer | Creates | State | Torn down |
|---|---|---|---|
| `ips/` | `seed_count` Elastic IPs (`<name_prefix>-seed-<i>`) | its own state file | never (`prevent_destroy`) |
| `nodes/` | a small VPC (one public /24 per zone, no NAT), a security group, an SSM-only instance role, and per seed: a network interface carrying the Elastic IP, an encrypted gp3 data volume, an instance | its own state file | any time |

`nodes/` takes the addresses as a variable (`seeds`, the `ips/` output of the same name). The
caller passes it from the `ips/` state with a `terraform_remote_state` data source, so the two
layers never share a state file and a mistake in `nodes/` cannot touch an address.

### What each seed is

- **Inbound:** TCP 18833 (P2P) from `p2p_ingress_cidrs` (default everyone) and nothing else.
  There is no SSH. A shell is `aws ssm start-session --target <instance id>` (SSM Session
  Manager; the instance role has `AmazonSSMManagedInstanceCore` and nothing more).
- **Outbound:** open (peers, the image registry, Ubuntu's mirror, the prefix release, SSM).
- **Instance:** Ubuntu 24.04 LTS (Canonical's AMI from AWS's public SSM parameter), default
  `t3a.small` (2 vCPU, 2 GiB, x86_64) with a 2 GiB swap file. IMDSv2 required, hop limit 1, both
  volumes encrypted.
- **The node:** `files/setup.sh` runs once per instance from cloud-init. It:
  - installs Docker;
  - mounts the data volume, formatting it only if it has no filesystem;
  - writes a compose file that runs the `ycashd` image (by digest) with `YCASHD_NETWORK=testnet`;
  - keeps the datadir on the data volume, with `restart: unless-stopped` and host networking;
  - binds RPC to `127.0.0.1` only;
  - passes `-externalip=<its Elastic IP>`, `-addnode=<every other seed>` and `-dnsseed=0`.
- **Optional bootstrap** (`prefix`): on an empty data volume the seed fetches the published
  Zcash-testnet prefix with the testnet chart's own `prefix-restore.sh`. That script refuses unless
  `SHA256SUMS` hashes to the pin and every file checks. The seed then frames the chunks with
  `bundles/prefix/import/frame.py` (with the testnet magic) and imports them with `-loadblock`.
  A timer drops the flags and the framed copies once the node reaches `last_height`. Both scripts
  come from the same commit of this repository as the module, so nothing extra is fetched.
  A refused bundle stops the setup: the node does not start (see `/var/log/cloud-init-output.log`
  through SSM).

## What survives what

| | Redeploy (new image or settings) | Reset (new testnet chain) | `terraform destroy` of `nodes/` |
|---|---|---|---|
| Elastic IP | kept | kept | kept (other layer) |
| Network interface | kept | kept | removed |
| Data volume (chain) | **kept** | **replaced (wiped)** | removed |
| Instance | replaced | replaced | removed |

**Redeploy** = change `image` (or any setting that reaches the machine) and apply. The instance's
cloud-init changes, so Terraform replaces the instance. The `aws_volume_attachment` stops it
cleanly first (`stop_instance_before_detaching`). The new instance boots with the same network
interface (so the same address) and the same data volume (so the same chain).

This is **destroy-then-create**, not `create_before_destroy`. An EBS volume and a primary network
interface can each belong to one running instance at a time, so a new instance could not take
them while the old one still runs. A seed is down for a few minutes during its replacement. To
roll one seed at a time, set `image_overrides = { "seed-0" = "<new digest>" }` (a canary) and
apply, check it, then move `image` and drop the override.

**Reset** = replace the data volumes:
`terraform apply -replace='module.nodes.aws_ebs_volume.data["seed-0"]' …`, one `-replace` per
seed. The private repository's `reset` action builds that list from the state. The volume id is
part of each instance's cloud-init, so the instances are replaced with them and start on empty
disks (and re-import the prefix, if set). The addresses do not change, so no node release needs
new fixed seeds.

**Retiring an address** (deliberate, rare): in the `ips/` root,
`terraform state rm 'module.ips.aws_eip.seed["seed-2"]'`, then release it in the EC2 console.
A lower `seed_count` alone is refused.

## Cost estimate

On-demand prices in us-east-1, as of 2026-10. Other regions are within about 20 percent.

| Item | Per seed, per month |
|---|---|
| `t3a.small` instance (730 h × $0.0188) | $13.72 |
| gp3 storage, 40 GiB data + 16 GiB root (× $0.08) | $4.48 |
| Public IPv4 address (730 h × $0.005, charged for Elastic IPs in use or idle) | $3.65 |
| **Subtotal** | **≈ $21.85** |

- **Three seeds: ≈ $66/month**, plus data transfer out. The first 100 GB/month per account is
  free, then $0.09/GB. Every new node that syncs from a seed downloads the chain from it.
- CPU credits in `unlimited` mode: the first sync may cost a few cents extra.
- SSM Session Manager: no charge. Terraform state in S3: cents.
- With `nodes/` torn down and `ips/` kept, the three idle addresses cost ≈ $11/month.
- An arm64 `t4g.small` is ≈ $1.50/month cheaper per seed. It needs an arm64 image, which the
  `node-image` workflow does not build today.

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
  source     = "git::https://github.com/boyfromcave/ycash-infra.git//infra/testnet-seeds/ips?ref=<sha>"
  seed_count = 3
}
output "public_ips" { value = module.ips.public_ips }
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
  source             = "git::https://github.com/boyfromcave/ycash-infra.git//infra/testnet-seeds/nodes?ref=<sha>"
  seeds              = data.terraform_remote_state.ips.outputs.seeds
  availability_zones = ["<region>a", "<region>b", "<region>c"]
  image              = "ghcr.io/boyfromcave/ycashd@sha256:<digest>"
}
output "public_ips" { value = module.nodes.public_ips }
```

`ips/example.tfvars` and `nodes/example.tfvars` list every variable with fake values, and
`variables.tf` documents each one. Neither directory has a provider block or a backend, so the
caller chooses the account, the region and the state location. Each directory's `versions.tf`
shows a backend example as comments. The provider is pinned exactly (`hashicorp/aws` 6.70.0);
the caller's `.terraform.lock.hcl` records its hashes.

The node image must be pullable without credentials. The `node-image` workflow pushes to
`ghcr.io/boyfromcave/ycashd`, and that package must be set to public once, in its package
settings.

## Checks

`make seeds-validate`, also run in CI's `eks` job, does three things, offline, with no AWS
credentials and no plan:
- `terraform fmt -check` on both directories;
- `terraform validate` on both directories;
- `shellcheck` on the seed's scripts.
