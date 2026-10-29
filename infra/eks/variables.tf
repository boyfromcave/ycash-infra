# The example root's variables (terraform.tfvars, from terraform.tfvars.example; gitignored). The
# module documents each one (module/variables.tf).
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
variable "domain" {
  type        = string
  description = "The public hostname of the gateway (or a parent of every gateway host), e.g. lite.example.org; inside the hosted zone."
}
variable "hosted_zone_id" {
  type        = string
  description = "Route53 hosted zone id (Z...) holding `domain`."
}
variable "acme_email" {
  type        = string
  description = "Let's Encrypt account contact for the ClusterIssuer (a role address)."
}
variable "secrets_prefix" {
  type    = string
  default = "ycash/lite"
}
variable "networks" {
  type    = set(string)
  default = []
}
variable "cluster_admin_arns" {
  type    = list(string)
  default = []
}
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
