locals {
  nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length

  max_subnet_length = max(
    length(var.private_subnets)
  )
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = {
    "Name" = "${var.name}"
  }
}

resource "aws_security_group_rule" "default_rule" {
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_vpc.vpc.default_security_group_id
}

################################################################################
# Internet Gateway
################################################################################
resource "aws_internet_gateway" "igw" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc.id

  tags = {
    "Name" = "${var.name}"
  }
}

################################################################################
# Publiс route tables
################################################################################
resource "aws_route_table" "public" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc.id
  tags = {
    "Name" = "${var.name}-public"
  }
}

resource "aws_route" "public_internet_gateway" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw[0].id

  timeouts {
    create = "5m"
  }
}

################################################################################
# Private route tables
# There are as many routing tables as the number of NAT gateways
# Currently the number of NAT gateways are equal to the number of azs
# Create private route only there are at least 1 subnet that need to be private (private_subnet, database_subnet, etc...)
################################################################################

resource "aws_route_table" "private" {
  count = local.max_subnet_length > 0 ? local.nat_gateway_count : 0

  vpc_id = aws_vpc.vpc.id
  tags = {
    "Name" = "${var.name}-private-${count.index}"
  }
}

################################################################################
# Public subnet
################################################################################

resource "aws_subnet" "public" {
  count = length(var.public_subnets) > 0 ? length(var.public_subnets) : 0

  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = {
    "Name" = "${var.name}-public-${element(var.azs, count.index)}"
  }
}

################################################################################
# Private subnet
################################################################################

resource "aws_subnet" "private" {
  count = length(var.private_subnets) > 0 ? length(var.private_subnets) : 0

  vpc_id               = aws_vpc.vpc.id
  cidr_block           = var.private_subnets[count.index]
  availability_zone    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null

  tags = {
    "Name" = "${var.name}-private-${element(var.azs, count.index)}"
  }
}

################################################################################
# Isolated subnet
################################################################################

resource "aws_subnet" "isolated" {
  count = length(var.isolated_subnets) > 0 ? length(var.isolated_subnets) : 0

  vpc_id               = aws_vpc.vpc.id
  cidr_block           = var.isolated_subnets[count.index]
  availability_zone    = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) > 0 ? element(var.azs, count.index) : null
  availability_zone_id = length(regexall("^[a-z]{2}-", element(var.azs, count.index))) == 0 ? element(var.azs, count.index) : null

  tags = {
    "Name" = "${var.name}-isolated-${element(var.azs, count.index)}"
  }
}

resource "aws_db_subnet_group" "rds" {
  count = length(var.database_subnets) > 0 && var.create_database_subnet_group ? 1 : 0

  name        = lower(coalesce(var.database_subnet_group_name, var.name))
  description = "Database subnet group for ${var.name}"
  subnet_ids  = aws_subnet.isolated.*.id

  tags = {
    "Name" = "${lower(coalesce(var.database_subnet_group_name, var.name))}"
  }
}

################################################################################
# NAT Gateway
################################################################################
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  vpc = true

  tags = {
    "Name" = "${var.name}-${element(var.azs, count.index)}"
  }
}

resource "aws_nat_gateway" "nat" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  allocation_id = element(aws_eip.nat.*.id, count.index)
  subnet_id     = element(aws_subnet.public.*.id, count.index)

  depends_on = [aws_internet_gateway.igw]

  tags = {
    "Name" = "${var.name}-${element(var.azs, count.index)}"
  }
}

# Create route of the private subnet since these subnets will need NAT gateway
# The other subnets that fully private do not need the NAT gateway
resource "aws_route" "nat" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  route_table_id         = element(aws_route_table.private.*.id, count.index)
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = element(aws_nat_gateway.nat.*.id, count.index)

  timeouts {
    create = "5m"
  }
}

################################################################################
# Route table association
################################################################################
resource "aws_route_table_association" "private" {
  count = length(var.private_subnets) > 0 ? length(var.private_subnets) : 0

  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, var.single_nat_gateway ? 0 : count.index)
  depends_on = [
    aws_subnet.private,
    aws_route_table.private
  ]
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnets) > 0 ? length(var.public_subnets) : 0

  subnet_id      = element(aws_subnet.public.*.id, count.index)
  route_table_id = aws_route_table.public[0].id

  depends_on = [
    aws_subnet.public[0],
    aws_route_table.public[0]
  ]
}