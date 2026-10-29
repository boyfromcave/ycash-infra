# Everything that is account- or operator-specific is a variable here; nothing in this directory
# names an account, a bucket, a person or a region.

variable "seeds" {
  description = "The seed addresses, as the ips layer's `seeds` output: { seed-0 = { allocation_id, public_ip }, ... }. One instance per entry."
  type = map(object({
    allocation_id = string
    public_ip     = string
  }))
  validation {
    condition     = length(var.seeds) >= 1 && alltrue([for k, s in var.seeds : can(regex("^[a-z0-9-]{1,32}$", k)) && can(regex("^eipalloc-[0-9a-f]+$", s.allocation_id)) && can(cidrhost("${s.public_ip}/32", 0))])
    error_message = "seeds: at least one entry; keys of lowercase letters, digits and dashes; allocation_id eipalloc-...; public_ip an IPv4 address."
  }
}

variable "availability_zones" {
  description = "Zones to spread the seeds over, round robin in key order (seed-0 in the first). Two or more is recommended."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 1 && length(var.availability_zones) <= 6
    error_message = "availability_zones: 1 to 6 zones of the provider's region."
  }
}

variable "name_prefix" {
  description = "Prefix of every resource's Name tag and of the IAM role name. Keep it generic."
  type        = string
  default     = "testnet-seed"
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
  description = "The seeds' own small VPC (one public subnet per zone, a /24 each, no NAT)."
  type        = string
  default     = "10.77.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be an IPv4 CIDR of /16 to /20 (each zone gets a subnet 8 bits longer)."
  }
}

variable "image" {
  description = "The ycashd image, by digest: <repository>@sha256:<64 hex> (for example the node-image workflow's ghcr.io/<owner>/ycashd@sha256:...). Changing it replaces every instance whose seed has no override; the addresses and data volumes stay."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest: <repository>@sha256:<64 lowercase hex>."
  }
}

variable "image_overrides" {
  description = "Per seed, an image that replaces `image` for that seed only: the canary of a rolling upgrade (one seed first, then `image` for the rest)."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k, v in var.image_overrides : can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", v))])
    error_message = "every image_overrides value must be pinned by digest."
  }
}

variable "architecture" {
  description = "CPU architecture of the instances and the image: x86_64 or arm64. The image must have a variant for it (the node-image workflow builds linux/amd64 only)."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture: x86_64 or arm64."
  }
}

variable "instance_type" {
  description = "Instance type; must match `architecture` (t3a.* / t3.* for x86_64, t4g.* for arm64)."
  type        = string
  default     = "t3a.small"
}

variable "cpu_credits" {
  description = "Burstable CPU credit mode: unlimited lets the first sync run at full speed (a few cents of surplus credits), standard caps the bill and throttles."
  type        = string
  default     = "unlimited"
  validation {
    condition     = contains(["standard", "unlimited"], var.cpu_credits)
    error_message = "cpu_credits: standard or unlimited."
  }
}

variable "ami_id" {
  description = "AMI override. Empty = Canonical's current Ubuntu 24.04 LTS for `architecture`, read from AWS's public SSM parameter at instance creation (later AMI releases never replace a running instance)."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root volume (OS, Docker, the image, swap), GiB, gp3, encrypted. Replaced with the instance."
  type        = number
  default     = 16
}

variable "data_volume_size" {
  description = "Data volume (the node's datadir), GiB, gp3, encrypted. Kept across redeploys, replaced on reset. The prefix import needs about 2.1 GB on top of the chain while it runs."
  type        = number
  default     = 40
}

variable "kms_key_id" {
  description = "KMS key for both volumes. Null = the account's default EBS key (aws/ebs)."
  type        = string
  default     = null
}

variable "swap_mb" {
  description = "Swap file on the root volume, MiB (0 = none). Gives a 2 GiB instance headroom during the first sync."
  type        = number
  default     = 2048
}

variable "p2p_port" {
  description = "The P2P port the security group opens and the node is told to advertise. The testnet's is 18833 (compiled into the node)."
  type        = number
  default     = 18833
}

variable "p2p_ingress_cidrs" {
  description = "Who may open a P2P connection. Seeds serve everyone: 0.0.0.0/0. Nothing else is ever opened inbound (no SSH; management is SSM Session Manager)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_args" {
  description = "Appended to ycashd's command line on every seed (for example -dbcache=512). Each seed already gets -externalip=<its address>, -addnode=<every other seed> and -dnsseed=0."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9=:._,/ +-]*$", var.extra_args))
    error_message = "extra_args: letters, digits, spaces and = : . _ , / + - only (no quotes or shell characters)."
  }
}

variable "prefix" {
  description = <<-EOT
    Optional bootstrap from the testnet prefix release (bundles/prefix/FORMAT.md): on an empty data
    volume the seed downloads it from base_url, refuses unless SHA256SUMS hashes to sums_sha256 and
    every file checks, frames it with `magic` (bundles/prefix/import/frame.py) and imports it with
    -loadblock. Null = no bootstrap: the seed syncs from its peers.
  EOT
  type = object({
    base_url    = string
    sums_sha256 = string
    last_height = number
    magic       = string
  })
  default = null
  validation {
    condition = var.prefix == null ? true : (
      can(regex("^https://[A-Za-z0-9._~/%-]+$", var.prefix.base_url)) &&
      can(regex("^[0-9a-f]{64}$", var.prefix.sums_sha256)) &&
      can(regex("^[0-9a-f]{8}$", var.prefix.magic)) &&
      var.prefix.last_height > 0
    )
    error_message = "prefix: base_url https://..., sums_sha256 64 lowercase hex, magic 8 lowercase hex, last_height > 0."
  }
}
