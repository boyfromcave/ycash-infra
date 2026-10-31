# Everything account- or operator-specific is a variable without a default: the bucket, the zones,
# the repository and commit the instance runs. Nothing in this directory names an account, a bucket,
# a region, a domain or a person.

variable "bucket_name" {
  description = "Name of the results bucket this module creates (runs/ for logs and status, prefix/ for the published bundles). S3 names are global and public once anything is shared from the bucket: pick a neutral one (for example a random suffix). Supplied by the caller, never committed here."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name)) && !strcontains(var.bucket_name, "--")
    error_message = "bucket_name: 3 to 63 lowercase letters, digits and single dashes, starting and ending with a letter or digit (no dots: the bundle is fetched over HTTPS by virtual-hosted name)."
  }
}

variable "availability_zones" {
  description = "Zones of the provider's region to make a public subnet in, one each. The workflow launches into them in order until one has capacity, so two or three widen the spot pool."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 1 && length(var.availability_zones) <= 6
    error_message = "availability_zones: 1 to 6 zones of the provider's region."
  }
}

variable "infra_repo_url" {
  description = "The ycash-infra repository the instance clones (HTTPS, public): it runs bundles/prefix from there."
  type        = string
  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$", var.infra_repo_url))
    error_message = "infra_repo_url: an https:// URL of plain characters."
  }
}

variable "infra_commit" {
  description = "The full commit of infra_repo_url the instance checks out and runs (bundles/prefix/run-local-mainnet.sh and its tools). Pin the same commit as this module's source."
  type        = string
  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.infra_commit))
    error_message = "infra_commit: a full 40-hex commit id."
  }
}

variable "name_prefix" {
  description = "Name of the launch template, prefix of every Name tag and of the IAM role and instance profile names. Keep it generic."
  type        = string
  default     = "mainnet-harvest"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.name_prefix))
    error_message = "name_prefix: lowercase letters, digits and dashes, starting with a letter, at most 31 characters."
  }
}

variable "tags" {
  description = "Extra tags on every resource. Keep them generic: no names, no account details."
  type        = map(string)
  default     = {}
}

variable "vpc_cidr" {
  description = "The harvest's own small VPC (one public subnet per zone, a /24 each, no NAT)."
  type        = string
  default     = "10.78.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be an IPv4 CIDR of /16 to /20 (each zone gets a subnet 8 bits longer)."
  }
}

variable "instance_type" {
  description = "x86_64 instance type (the ycashd image is linux/amd64). Two nodes sync side by side with -dbcache each, then gzip runs on every core: m7a.2xlarge (8 vCPU, 32 GiB) leaves room for both; m7a.xlarge (16 GiB) fits with dbcache 2048."
  type        = string
  default     = "m7a.2xlarge"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*\\.[a-z0-9]+$", var.instance_type)) && !can(regex("^[a-z]+[0-9]+g", var.instance_type))
    error_message = "instance_type: an x86_64 type such as m7a.2xlarge (no Graviton *g types)."
  }
}

variable "ami_id" {
  description = "AMI override. Empty = Canonical's current Ubuntu 24.04 LTS (amd64) from AWS's public SSM parameter, read at every apply: a newer AMI becomes the launch template's next default version. An override must use /dev/sda1 as its root device, as Ubuntu's do."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root volume (OS, Docker, the images), GiB, gp3, encrypted, deleted with the instance."
  type        = number
  default     = 30
  validation {
    condition     = var.root_volume_size >= 16
    error_message = "root_volume_size: at least 16 GiB."
  }
}

variable "data_volume_size" {
  description = "Data volume, GiB, gp3, encrypted, deleted with the instance: two node datadirs, the raw copy and the packed bundle at the peak (bundles/prefix/README.md, \"Sizes\": 300 to 400 GB)."
  type        = number
  default     = 500
  validation {
    condition     = var.data_volume_size >= 100 && var.data_volume_size <= 16384
    error_message = "data_volume_size: 100 to 16384 GiB."
  }
}

variable "data_volume_iops" {
  description = "Data volume IOPS (gp3: 3000 included; the sync is I/O-bound, so a little more pays for itself)."
  type        = number
  default     = 6000
  validation {
    condition     = var.data_volume_iops >= 3000 && var.data_volume_iops <= 16000
    error_message = "data_volume_iops: 3000 to 16000."
  }
}

variable "data_volume_throughput" {
  description = "Data volume throughput, MiB/s (gp3: 125 included)."
  type        = number
  default     = 250
  validation {
    condition     = var.data_volume_throughput >= 125 && var.data_volume_throughput <= 1000
    error_message = "data_volume_throughput: 125 to 1000 MiB/s."
  }
}

variable "kms_key_id" {
  description = "KMS key for both volumes. Null = the account's default EBS key (aws/ebs)."
  type        = string
  default     = null
}

variable "max_hours" {
  description = "Hard lifetime of an instance, hours: it powers off (and so is terminated, disks and all) this long after boot whatever its state. The sync is stopped cleanly reserve_minutes earlier."
  type        = number
  default     = 48
  validation {
    condition     = var.max_hours >= 2 && var.max_hours <= 168 && floor(var.max_hours) == var.max_hours
    error_message = "max_hours: a whole number of hours, 2 to 168."
  }
}

variable "reserve_minutes" {
  description = "Minutes of the lifetime kept for export, pack, upload and read-back after the sync (SYNC_TIMEOUT_MIN = max_hours * 60 - reserve_minutes, at least 60)."
  type        = number
  default     = 360
  validation {
    condition     = var.reserve_minutes >= 30 && floor(var.reserve_minutes) == var.reserve_minutes
    error_message = "reserve_minutes: a whole number, at least 30."
  }
}

variable "split_height" {
  description = "Default H_S: auto (the most recent k*10,000 - 1 at least 1,000 blocks below the synced tip) or a height. A launch may override it with the instance tag HarvestSplitHeight."
  type        = string
  default     = "auto"
  validation {
    condition     = can(regex("^(auto|[0-9]{1,8})$", var.split_height))
    error_message = "split_height: auto or a height."
  }
}

variable "crosscheck" {
  description = "Default cross-check (run-local-mainnet.sh CROSSCHECK): sync (a second node syncs alongside) or none (only for H_S <= 2,250,000, i.e. trials). Instance tag HarvestCrosscheck overrides it."
  type        = string
  default     = "sync"
  validation {
    condition     = contains(["sync", "none"], var.crosscheck)
    error_message = "crosscheck: sync or none."
  }
}

variable "release_tag" {
  description = "Default bundle name: the bundle goes to prefix/<release_tag>/ in the bucket, once (never overwritten). Instance tag HarvestReleaseTag overrides it (a trial uses its own name)."
  type        = string
  default     = "mainnet-prefix-v1"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{0,62}$", var.release_tag))
    error_message = "release_tag: lowercase letters, digits, dots and dashes."
  }
}

variable "addnodes_url" {
  description = "Page fetch_addnodes.py reads the mainnet peers from at run time. Empty = the script's own default (the Ycash explorer's network page)."
  type        = string
  default     = ""
  validation {
    condition     = var.addnodes_url == "" || can(regex("^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/?=&-]*)?$", var.addnodes_url))
    error_message = "addnodes_url: empty or an https URL of plain characters."
  }
}

variable "dbcache" {
  description = "ycashd -dbcache, MiB, for each of the two nodes."
  type        = number
  default     = 4096
  validation {
    condition     = var.dbcache >= 256 && floor(var.dbcache) == var.dbcache
    error_message = "dbcache: a whole number of MiB, at least 256."
  }
}

variable "status_interval_seconds" {
  description = "How often the instance copies its status and log to runs/<run>/ in the bucket."
  type        = number
  default     = 300
  validation {
    condition     = var.status_interval_seconds >= 60
    error_message = "status_interval_seconds: at least 60."
  }
}

variable "run_log_days" {
  description = "Days the objects under runs/ (status, logs, results) are kept. prefix/ (the bundles) never expires."
  type        = number
  default     = 90
  validation {
    condition     = var.run_log_days >= 1
    error_message = "run_log_days: at least 1."
  }
}

variable "public_prefix" {
  description = "Allow anonymous HTTPS reads of prefix/* (the published bundles), so nodes can download a bundle by URL. Everything else in the bucket stays private either way. Every public download is S3 data transfer out, billed to the account."
  type        = bool
  default     = false
}
