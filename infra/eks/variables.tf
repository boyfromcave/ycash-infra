variable "region"             { default = "us-east-1" }
variable "name"               { default = "ycash-lite" }
variable "kubernetes_version" { default = "1.31" }
variable "node_instance_types" { default = ["m6i.xlarge"] }
variable "node_min"           { default = 2 }
variable "node_max"           { default = 10 }
variable "node_desired"       { default = 3 }
variable "single_nat_gateway" { default = true }
variable "hosted_zone_arns"   { type = list(string), default = [] }
