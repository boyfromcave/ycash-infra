variable "region" {
  type    = string
  default = "us-east-1"
}
variable "name" {
  type    = string
  default = "ycash-lite"
}
variable "kubernetes_version" {
  type    = string
  default = "1.31"
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

# The public host the gateway serves (values-eks.yaml gateway.host) and the Route53 zone it is
# in: external-dns writes the record, cert-manager solves DNS-01 there.
variable "domain" {
  type        = string
  description = "The public hostname of the gateway, e.g. lite.example.org (must be inside the hosted zone)."
}
variable "hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone id (Z...) holding `domain`."
}
variable "acme_email" {
  type        = string
  description = "Let's Encrypt account contact for the ClusterIssuer."
}

# Secrets Manager prefix for the two secrets External Secrets reads (values-eks.yaml externalSecrets.*).
variable "secrets_prefix" {
  type    = string
  default = "ycash/lite"
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
