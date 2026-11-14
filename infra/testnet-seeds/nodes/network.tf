# The seeds' own VPC: one public /24 per zone, an internet gateway, no NAT (nothing here is private,
# and a NAT gateway would cost more than the seeds). It is torn down and rebuilt with the nodes
# layer; the Elastic IPs are regional and do not depend on it.
# No VPC flow logs: the only inbound traffic is public P2P, which the node logs itself; flow logs
# would cost more than they show here.
resource "aws_vpc" "seeds" {
  #checkov:skip=CKV2_AWS_11:public P2P only; flow logs cost more than they show for a testnet seed
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name_prefix })
}

# The VPC's default security group admits nothing (it would otherwise allow all traffic between
# members); every seed uses aws_security_group.seed below.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.seeds.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-default-closed" })
}

resource "aws_internet_gateway" "seeds" {
  vpc_id = aws_vpc.seeds.id
  tags   = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "public" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id            = aws_vpc.seeds.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)
  # The seed's address is its Elastic IP, on its network interface before the instance boots.
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.seeds.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.seeds.id
  }
  tags = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Inbound: each enabled network's P2P port (to var.p2p_ingress_cidrs), for a network with a pool its
# stratum port (to var.pool_ingress_cidrs) and, for a network with an explorer, 443 and 80 (to
# var.explorer_ingress_cidrs; the explorer's proxy is the only listener there); nothing else. No
# SSH, no RPC: every node's RPC binds to 127.0.0.1 on its own port (an explorer's node: inside its
# container, reachable only from Inzyght's address), yolo's status page too, and an operator reaches
# a host through SSM, which needs no inbound port. Disabling or removing a network (or its pool or
# explorer) closes its ports.
resource "aws_security_group" "seed" {
  name_prefix = "${var.name_prefix}-"
  description = "Seed hosts: inbound P2P of the enabled networks only, egress open"
  vpc_id      = aws_vpc.seeds.id
  tags        = merge(var.tags, { Name = var.name_prefix })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "p2p" {
  for_each = { for p in setproduct(sort(keys(local.enabled)), var.p2p_ingress_cidrs) : "${p[0]} ${p[1]}" => { net = p[0], cidr = p[1] } }

  security_group_id = aws_security_group.seed.id
  description       = "P2P ${each.value.net}"
  ip_protocol       = "tcp"
  from_port         = local.enabled[each.value.net].p2p_port
  to_port           = local.enabled[each.value.net].p2p_port
  cidr_ipv4         = each.value.cidr
  tags              = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "stratum" {
  for_each = { for p in setproduct(sort([for k, n in local.enabled : k if n.pool != null]), var.pool_ingress_cidrs) : "${p[0]} ${p[1]}" => { net = p[0], cidr = p[1] } }

  security_group_id = aws_security_group.seed.id
  description       = "stratum ${each.value.net}"
  ip_protocol       = "tcp"
  from_port         = local.enabled[each.value.net].pool.port
  to_port           = local.enabled[each.value.net].pool.port
  cidr_ipv4         = each.value.cidr
  tags              = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "explorer" {
  #checkov:skip=CKV_AWS_260:a public explorer: port 80 for the Let's Encrypt HTTP-01 challenge and the redirect to HTTPS
  for_each = { for p in setproduct(sort([for k, n in local.enabled : k if n.explorer != null]), [443, 80], var.explorer_ingress_cidrs) : "${p[0]} ${p[1]} ${p[2]}" => { net = p[0], port = p[1], cidr = p[2] } }

  security_group_id = aws_security_group.seed.id
  description       = "explorer ${each.value.net} ${each.value.port == 443 ? "https" : "http (ACME, redirect)"}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  tags              = var.tags
}

# Egress open: P2P to any peer, the image registry, the package mirror, the prefix release and the
# SSM endpoints.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.seed.id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}
