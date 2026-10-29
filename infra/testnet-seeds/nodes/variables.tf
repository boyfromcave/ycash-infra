# Everything that is account- or operator-specific is a variable here; nothing in this directory
# names an account, a bucket, a person or a region.

variable "seeds" {
  description = "The seed host addresses, as the ips layer's `seeds` output: { seed-0 = { allocation_id, public_ip }, ... }. One instance per entry; every instance serves every enabled network."
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
  description = "Zones to spread the hosts over, round robin in key order (seed-0 in the first). Two or more is recommended."
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
  description = "The hosts' own small VPC (one public subnet per zone, a /24 each, no NAT)."
  type        = string
  default     = "10.77.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 0))
    error_message = "vpc_cidr must be an IPv4 CIDR of /16 to /20 (each zone gets a subnet 8 bits longer)."
  }
}

variable "image" {
  description = "The default ycashd image of every network, by digest: <repository>@sha256:<64 hex> (for example the node-image workflow's ghcr.io/<owner>/ycashd@sha256:...). One image serves every profile: the profile is a runtime argument. A network's own `image` overrides it. Changing it changes no AWS resource: seedctl rolls it out (README.md, \"Per-network lifecycle\")."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest: <repository>@sha256:<64 lowercase hex>."
  }
}

variable "networks" {
  description = <<-EOT
    The networks every host serves, one container each: { <key> = { profile, enabled, image,
    bootstrap, extra_args } }. The key names the network in seedctl, in the container name
    (ycashd-<key>) and in its data directory; the profile picks the ports, the magic and the node
    arguments (locals.tf, `profiles`): fast, slow and legacy are the three testnets
    (-testnet -testnetprofile=<profile>), main is mainnet (no -testnet; a separate stack, never
    beside a testnet). Adding or removing a network is one entry. `image` overrides var.image for
    that network; `bootstrap` (default true) imports var.prefix into an empty datadir (testnet
    profiles only); `extra_args` is appended after var.extra_args.
  EOT
  type = map(object({
    profile    = string
    enabled    = optional(bool, true)
    image      = optional(string)
    bootstrap  = optional(bool, true)
    extra_args = optional(string, "")
  }))
  default = {
    yb-fast = { profile = "fast" }
    yb-slow = { profile = "slow" }
    legacy  = { profile = "legacy" }
    main    = { profile = "main", enabled = false }
  }
  validation {
    condition     = alltrue([for k, n in var.networks : can(regex("^[a-z][a-z0-9-]{0,15}$", k)) && contains(["fast", "slow", "legacy", "main"], n.profile)])
    error_message = "networks: keys of lowercase letters, digits and dashes (at most 16, starting with a letter); profile one of fast, slow, legacy, main."
  }
  validation {
    condition     = alltrue([for k, n in var.networks : n.image == null || can(regex("^[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}$", coalesce(n.image, "-")))])
    error_message = "networks: every image override must be pinned by digest."
  }
  validation {
    condition     = alltrue([for k, n in var.networks : can(regex("^[A-Za-z0-9=:._,/ +-]*$", n.extra_args))])
    error_message = "networks: extra_args: letters, digits, spaces and = : . _ , / + - only."
  }
  validation {
    condition     = length([for k, n in var.networks : k if n.enabled]) >= 1
    error_message = "networks: at least one network must be enabled."
  }
  validation {
    condition     = length(distinct([for k, n in var.networks : n.profile if n.enabled])) == length([for k, n in var.networks : k if n.enabled])
    error_message = "networks: two enabled networks share a profile (and so its ports and magic)."
  }
  validation {
    condition     = !contains([for k, n in var.networks : n.profile if n.enabled], "main") || length([for k, n in var.networks : k if n.enabled]) == 1
    error_message = "networks: main is a stack of its own (own state, own addresses, own account), never enabled beside a testnet."
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
  description = "Instance type; must match `architecture` (t3a.* / t3.* for x86_64, t4g.* for arm64). t3a.medium (2 vCPU, 4 GiB) runs the three testnets."
  type        = string
  default     = "t3a.medium"
}

variable "cpu_credits" {
  description = "Burstable CPU credit mode: unlimited lets a first sync or an import run at full speed (a few cents of surplus credits), standard caps the bill and throttles."
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
  description = "Root volume (OS, Docker, the images, swap), GiB, gp3, encrypted. Replaced with the instance."
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "Data volume (every network's datadir side by side, and the shared verified prefix), GiB, gp3, encrypted. Kept across upgrades, resets and instance replacements. Per testnet a few GB today (the 510,248-block prefix plus the new chain), plus about 1.1 GB per network while its prefix import runs and 1.1 GB for the shared prefix cache."
  type        = number
  default     = 80
}

variable "kms_key_id" {
  description = "KMS key for both volumes. Null = the account's default EBS key (aws/ebs)."
  type        = string
  default     = null
}

variable "swap_mb" {
  description = "Swap file on the root volume, MiB (0 = none). Headroom for three nodes on 4 GiB during imports."
  type        = number
  default     = 4096
}

variable "p2p_ingress_cidrs" {
  description = "Who may open a P2P connection, on each enabled network's port. Seeds serve everyone: 0.0.0.0/0. Nothing else is ever opened inbound (no SSH, no RPC; management is SSM)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_args" {
  description = "Appended to ycashd's command line on every network of every host (a network's own extra_args follow it). Each node already gets -port, -externalip=<its address>, -addnode=<the other hosts on that network's port>, the profile's arguments and, on a testnet, -dnsseed=0. The default keeps three nodes inside 4 GiB."
  type        = string
  default     = "-dbcache=256 -maxconnections=64"
  validation {
    condition     = can(regex("^[A-Za-z0-9=:._,/ +-]*$", var.extra_args))
    error_message = "extra_args: letters, digits, spaces and = : . _ , / + - only (no quotes or shell characters)."
  }
}

variable "prefix" {
  description = <<-EOT
    Optional bootstrap from the shared testnet prefix release (bundles/prefix/FORMAT.md; it is
    magic-neutral, so all three testnets use the same one): on a testnet network's empty datadir the
    host downloads it once into its own cache, refuses unless SHA256SUMS hashes to sums_sha256 and
    every file checks, frames it with that network's magic (the profile's, locals.tf) and imports it
    with -loadblock. A reset reuses the verified cache. Null = no bootstrap: each network syncs from
    its peers.
  EOT
  type = object({
    base_url    = string
    sums_sha256 = string
    last_height = number
  })
  default = null
  validation {
    condition = var.prefix == null ? true : (
      can(regex("^https://[A-Za-z0-9._~/%-]+$", var.prefix.base_url)) &&
      can(regex("^[0-9a-f]{64}$", var.prefix.sums_sha256)) &&
      var.prefix.last_height > 0
    )
    error_message = "prefix: base_url https://..., sums_sha256 64 lowercase hex, last_height > 0."
  }
}

variable "prefix_magic_overrides" {
  description = "Per network key, the magic the prefix is framed with instead of its profile's: only for a node image from before the profiles existed (its compiled testnet magic, fa1af9bf). A wrong magic makes the node skip every framed block."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for k, m in var.prefix_magic_overrides : can(regex("^[0-9a-f]{8}$", m))])
    error_message = "prefix_magic_overrides: 8 lowercase hex digits each."
  }
}
