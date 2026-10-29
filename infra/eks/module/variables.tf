# Everything account- or operator-specific is a variable; nothing in this directory names an
# account, a person, a domain or a zone. The examples in descriptions are documentation values.

variable "name" {
  description = "Cluster name, and the prefix of the VPC, the IAM roles, the RDS instance and external-dns's ownership id. Keep it generic."
  type        = string
  default     = "ycash-lite"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.name))
    error_message = "name: lowercase letters, digits and dashes, starting with a letter, at most 31 characters."
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "vpc_cidr" {
  description = "The cluster's VPC, a /16: three private /19s (nodes), three public /22s (load balancers), three database /24s."
  type        = string
  default     = "10.40.0.0/16"
  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 114)) && endswith(var.vpc_cidr, "/16")
    error_message = "vpc_cidr must be an IPv4 /16."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m6i.xlarge"]
}
variable "node_min" {
  type    = number
  default = 2
}
variable "node_max" {
  type    = number
  default = 10
}
variable "node_desired" {
  type    = number
  default = 3
}
variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "cluster_admin_arns" {
  description = "IAM principals (role or user ARNs) given cluster-admin access entries besides the creator (the deploy role). Set by the caller from its private configuration; empty by default."
  type        = list(string)
  default     = []
}

# The DNS name external-dns may write under and the Route53 zone it is in: every gateway host of the
# charts deployed here must be this name or below it. cert-manager solves DNS-01 in the same zone.
variable "domain" {
  type        = string
  description = "The gateway host, or a parent of every gateway host (one per network), e.g. lite.example.org or testnet.example.org. Must be inside the hosted zone."
}
variable "hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone id (Z...) holding `domain`."
  validation {
    condition     = can(regex("^Z[A-Z0-9]{1,32}$", var.hosted_zone_id))
    error_message = "hosted_zone_id: the zone's id, Z followed by letters and digits."
  }
}
variable "acme_email" {
  type        = string
  description = "Let's Encrypt account contact for the ClusterIssuer: a role address, not a person's (Certificate Transparency logs the certificates, not the e-mail, but the CA keeps it)."
}

# Secrets Manager prefix for the secrets External Secrets reads (the charts' externalSecrets.*).
variable "secrets_prefix" {
  type    = string
  default = "ycash/lite"
}

variable "networks" {
  description = <<-EOT
    One namespace per network on one cluster (the testnets: yb-fast, yb-slow, legacy). For each,
    the module makes `<secrets_prefix>/<network>/ycashd-rpc` {rpcuser, rpcpassword} and
    `<secrets_prefix>/<network>/yindex-postgres` {url} pointing at its own database
    `yindex_<network>` on the one RDS instance (created by a Job in the cluster). Empty (the
    default, one mainnet light-wallet endpoint) = the two secrets without a network segment and the
    instance's `yindex` database, as before.
  EOT
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.networks : can(regex("^[a-z][a-z0-9-]{0,15}$", n))])
    error_message = "networks: lowercase letters, digits and dashes, starting with a letter, at most 16 characters."
  }
}

variable "ecr_prefix" {
  description = "ECR repositories are <ecr_prefix>/<image>."
  type        = string
  default     = "ycash"
}
variable "ecr_images" {
  description = "The images mirrored or pushed to ECR (one repository each, immutable tags). The testnet adds ycashd-legacy (the cross-line verifier)."
  type        = list(string)
  default     = ["ycashd", "lightwalletd", "yindex", "web"]
}

# RDS Postgres for yindex (rds.tf). db.t4g.small single-AZ is the plan's "small"; multi-AZ doubles it.
variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}
variable "rds_allocated_gb" {
  type    = number
  default = 20
}
variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "tags" {
  description = "Tags on every AWS resource that takes them, through the caller's provider default_tags is the alternative. Keep them generic."
  type        = map(string)
  default     = {}
}

# Add-on chart versions (addons.tf), pinned; kind-up.sh uses the same Envoy Gateway and cert-manager.
variable "addon_versions" {
  type = object({
    envoy_gateway         = string
    cert_manager          = string
    lb_controller         = string
    external_secrets      = string
    external_dns          = string
    kube_prometheus_stack = string
    metrics_server        = string
  })
  default = {
    envoy_gateway         = "v1.3.0"
    cert_manager          = "v1.17.1"
    lb_controller         = "1.11.0"
    external_secrets      = "0.17.0"
    external_dns          = "1.16.1"
    kube_prometheus_stack = "70.4.1"
    metrics_server        = "3.12.2"
  }
}
