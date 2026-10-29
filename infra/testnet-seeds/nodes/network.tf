# The seeds' own VPC: one public /24 per zone, an internet gateway, no NAT (nothing here is private,
# and a NAT gateway would cost more than the seeds). It is torn down and rebuilt with the nodes
# layer; the Elastic IPs are regional and do not depend on it.
resource "aws_vpc" "seeds" {
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

# Inbound: P2P only. No SSH, no RPC: RPC binds to 127.0.0.1 on the instance, and an operator reaches
# a shell through SSM Session Manager, which needs no inbound port.
resource "aws_security_group" "seed" {
  name_prefix = "${var.name_prefix}-"
  description = "Testnet seed: inbound P2P only, egress open"
  vpc_id      = aws_vpc.seeds.id
  tags        = merge(var.tags, { Name = var.name_prefix })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "p2p" {
  for_each = toset(var.p2p_ingress_cidrs)

  security_group_id = aws_security_group.seed.id
  description       = "P2P"
  ip_protocol       = "tcp"
  from_port         = var.p2p_port
  to_port           = var.p2p_port
  cidr_ipv4         = each.value
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
