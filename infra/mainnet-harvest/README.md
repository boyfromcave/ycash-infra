# infra/mainnet-harvest: the Ycash mainnet history bundle, made on a throwaway EC2 instance

## In plain words

Two of the Ycash testnets start from a copy of the real Ycash network's history (the "prefix",
`bundles/prefix/README.md`, "Mainnet history"). Making that copy means running a Ycash node until
it has downloaded the whole real chain, which takes a day or more and 300 to 400 GB of disk: too
long for GitHub's hosted machines (they stop after 6 hours) and too big for a laptop.

This directory describes, for AWS, a machine that does that job **once and then deletes itself**:

- a **storage bucket** for the results. The finished bundle goes into it, plus a small status
  file and the log of each run, so you can follow a run without logging in anywhere;
- a **recipe for the machine** (an EC2 "launch template"): Ubuntu, a big temporary disk, and a
  start-up script that installs Docker, downloads this repository at one fixed version, runs the
  harvest, uploads the result, checks the upload byte for byte, and switches the machine off.
  Switched off means deleted, disks included, so nothing keeps costing money;
- a **safety timer**: whatever happens, the machine switches itself off after a set number of
  hours (48 by default), so a stuck run can never bill for ever;
- a tiny private network with **no way in**: the machine only connects out (to Ycash peers, to
  GitHub, to the bucket). There is no SSH; an operator who wants a look uses AWS's Session
  Manager.

Nothing here starts a machine. The operator's own workflow (in a private repository) presses
"start" when a harvest is wanted; the machine tags itself with a run id and reports into the
bucket. Nothing in this directory names an AWS account, a bucket, a region or a person: all of
those are the caller's values.

## What it creates

| Resource | Notes | Cost while idle |
|---|---|---|
| S3 bucket `bucket_name` | private; SSE-S3; versioning off; TLS only; `runs/` expires after `run_log_days` (90); unfinished uploads aborted after 7 days; `force_destroy` off, so a `destroy` fails while a bundle is in it | storage only |
| Bucket policy | TLS-only deny; with `public_prefix = true` also anonymous `s3:GetObject` on `prefix/*` and nothing else | none |
| VPC, one public /24 per zone, internet gateway, route table | no NAT gateway; the VPC's default security group closed | none |
| Security group | no ingress rule at all; egress open | none |
| IAM role + instance profile (`<name_prefix>-…`) | `s3:PutObject` on `runs/*` and `prefix/*`, `s3:GetObject` on `prefix/*` (the read-back), `s3:ListBucket` on those prefixes, `AmazonSSMManagedInstanceCore`; no delete anywhere | none |
| Launch template `<name_prefix>` | below | none |

The launch template: Canonical's current Ubuntu 24.04 (amd64, from AWS's public SSM parameter at
each apply), `instance_type` (default `m7a.2xlarge`, 8 vCPU / 32 GiB: two nodes sync side by side),
IMDSv2 only with hop limit 1 and instance tags readable, a 30 GiB root and a `data_volume_size`
(500 GiB) gp3 data volume at 6000 IOPS / 250 MiB/s, both encrypted and deleted on termination,
`instance_initiated_shutdown_behavior = terminate`, and the cloud-init that runs
`files/harvest-run.sh`. It carries no spot setting: the launching workflow asks for spot or on
demand per launch, because a launch template's spot setting cannot be dropped by a launch that
falls back to on demand.

## What the instance does (`files/harvest-run.sh`)

1. `shutdown -h +<max_hours × 60>`: the lifetime cap, set before anything else.
2. Reads the run id and any per-run overrides from its own tags (`HarvestRun`,
   `HarvestSplitHeight`, `HarvestReleaseTag`, `HarvestCrosscheck`), validated; an invalid tag
   ends the run at once (exit 2).
3. Installs Docker, git and the AWS CLI; formats and mounts the data volume at `/data`.
4. Starts the status pusher: every `status_interval_seconds` (300) it copies `status.json` and the
   log to `runs/<run>/`, and it turns a spot interruption notice into `FAILED`, exit 7, before
   the instance is reclaimed.
5. Checks out `infra_repo_url` at `infra_commit` (full id, verified) and runs
   `bundles/prefix/fetch_addnodes.py` (exit 5 if the explorer lists no peer), then
   `bundles/prefix/run-local-mainnet.sh <split height>` with `CROSSCHECK`, the peer file and
   `SYNC_TIMEOUT_MIN = max_hours × 60 − reserve_minutes`, so a sync that cannot finish stops
   cleanly (exit 3) with time left to report.
6. On success: `bundles/prefix/publish-s3.sh out/ s3://<bucket>/prefix/<release_tag>` (refuses an
   existing bundle; index files last), then reads every file back from the bucket and compares it
   with `SHA256SUMS` (exit 6 on a mismatch), and writes `runs/<run>/result.json`
   (`last_height`, `sums_sha256`, `files`, `bytes`).
7. Writes the final `status.json` (`DONE` or `FAILED` with the exit code and the stage) and
   powers off, which terminates the instance.

`runs/<run>/` holds `status.json`, `harvest.log`, `timings.txt`, `harvest-report.json` and, when
done, `result.json`. The log never contains a peer address (`fetch_addnodes.py` prints a count;
`run-local-mainnet.sh` masks addresses).

## What survives what

| | A run ends (done, failed, cap) | Spot interruption | New module version / `apply` | `terraform destroy` |
|---|---|---|---|---|
| Instance, root and data volumes | **deleted** | **deleted** | not affected (a new template version is used by the next launch) | n/a |
| Node datadirs (the synced chain) | **deleted** with the data volume | **deleted** | n/a | n/a |
| `runs/<run>/` status and logs | kept, expire after `run_log_days` | kept (`FAILED`, exit 7) | kept | refused while the bucket has objects |
| `prefix/<release_tag>/` bundle | kept, never overwritten | (not written) | kept | refused while it is there |
| VPC, role, template | kept | kept | updated in place | removed |

A run is not resumable: each launch syncs from the start (the sync is the long part, and keeping
a datadir between runs would mean paying for a volume or snapshot while idle). A failed or
interrupted run is simply launched again.

## Cost (estimates, US regions, on demand prices; to be replaced by the first run's numbers)

| Item | Per run of about 24 to 36 hours |
|---|---|
| `m7a.2xlarge` spot (typically $0.15 to $0.25 an hour) | $4 to $9 (on demand, about $0.46 an hour: $11 to $17) |
| 500 GiB gp3 at 6000 IOPS / 250 MiB/s, plus the 30 GiB root, for the run's hours | about $3 |
| Public IPv4 address while running | about $0.20 |
| Upload to S3 in the same region; GitHub, mirror and peer traffic in | free |
| **One run** | **about $8 to $13 with spot** |

| Item | Ongoing |
|---|---|
| The bundle in S3 (60 to 90 GB compressed) | about $1.50 to $2.10 a month |
| `runs/` logs (megabytes, expiring) | cents |
| VPC, role, launch template, security group while idle | $0 |
| Each anonymous download of the full bundle (with `public_prefix`) | S3 data transfer out: the account's free 100 GB a month first, then about $0.09 per GB |

## Calling it from a private repository

```hcl
terraform {
  backend "s3" {} # terraform init -backend-config=backend.hcl (not committed)
}
provider "aws" { region = var.region }
module "harvest" {
  source             = "git::https://github.com/<owner>/ycash-infra.git//infra/mainnet-harvest?ref=<sha>"
  bucket_name        = var.harvest_bucket # a secret of the caller, never committed
  availability_zones = ["<region>a", "<region>b", "<region>c"]
  infra_repo_url     = "https://github.com/<owner>/ycash-infra.git"
  infra_commit       = "<sha>" # the same commit as the source
  public_prefix      = true    # nodes download the bundle by HTTPS URL
}
output "launch_template_name" { value = module.harvest.launch_template_name }
output "subnet_ids" { value = module.harvest.subnet_ids }
```

The launching side (the operator's workflow) then runs, per run:

```bash
aws ec2 run-instances --launch-template LaunchTemplateName=<name_prefix> --subnet-id <subnet> \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=<name_prefix>},{Key=HarvestRun,Value=<run id>}]'
```

and reads `runs/<run id>/status.json`. The role it uses needs `ec2:RunInstances` (and
`ec2:CreateTags` on launch), `iam:PassRole` on the instance role (to `ec2.amazonaws.com`),
`iam:CreateServiceLinkedRole` for `spot.amazonaws.com` (once per account, for spot),
`ec2:TerminateInstances` and `ec2:DescribeInstances`, and read access to the bucket.

When the bundle is served from the bucket, a node's `prefix.base_url` is the bucket's
virtual-hosted HTTPS address followed by `/prefix/<release_tag>`. The bucket name then becomes
public (the account ID does not), so choose a neutral one.

`variables.tf` documents every variable; `tests/render.tftest.hcl` uses placeholder values only.

## Tests

`make harvest-validate` (CI job `eks` in `ci.yml`): `terraform fmt`/`validate`, `terraform test`
against a mocked provider (no credentials), `shellcheck`, and `tests/harvest-run.sh`, which runs
`files/harvest-run.sh` against fakes (instance metadata, the AWS CLI with a local directory as
the bucket, disks, sudo, git) through a full run, a refused re-publish, a failed harvest, tag
overrides, an invalid tag and a spot notice.
