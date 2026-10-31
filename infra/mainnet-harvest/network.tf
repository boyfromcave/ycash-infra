# The harvest's own VPC: one public /24 per zone, an internet gateway, no NAT (a NAT gateway would
# cost more than the harvest). Idle, none of it costs anything; the instance's public IPv4 address
# is billed only while an instance runs.
# No VPC flow logs: nothing is inbound, and the instance logs what it does to the bucket.
resource "aws_vpc" "harvest" {
  #checkov:skip=CKV2_AWS_11:no inbound traffic at all; flow logs would cost more than they show for a one-shot job
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name_prefix })
}

# The VPC's default security group admits nothing; the instance uses aws_security_group.harvest.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.harvest.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-default-closed" })
}

resource "aws_internet_gateway" "harvest" {
  vpc_id = aws_vpc.harvest.id
  tags   = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_subnet" "public" {
  for_each = { for i, az in var.availability_zones : az => i }

  vpc_id            = aws_vpc.harvest.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)
  # The instance needs an address to reach Ycash peers, the package mirror and S3; it accepts no
  # inbound connection (the security group has no ingress rule).
  #checkov:skip=CKV_AWS_130:outbound-only instance; a public address is cheaper than a NAT gateway and nothing is inbound
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.name_prefix}-${each.key}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.harvest.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.harvest.id
  }
  tags = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Inbound: nothing. A shell is SSM Session Manager, which needs no inbound port.
resource "aws_security_group" "harvest" {
  name_prefix = "${var.name_prefix}-"
  description = "Mainnet harvest: no inbound, egress open"
  vpc_id      = aws_vpc.harvest.id
  tags        = merge(var.tags, { Name = var.name_prefix })

  lifecycle {
    create_before_destroy = true
  }
}

# Egress open: Ycash peers on whatever port the explorer lists, the explorer, GitHub, the image
# registry, Ubuntu's mirror and snap store, S3 and the SSM endpoints.
resource "aws_vpc_security_group_egress_rule" "all" {
  #checkov:skip=CKV_AWS_382:peers listen on ports the explorer reports at run time; the instance accepts nothing inbound
  security_group_id = aws_security_group.harvest.id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}
