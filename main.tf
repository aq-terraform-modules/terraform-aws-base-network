locals {
  nat_gateway_count = length(var.azs)

  max_subnet_length = max(
    length(var.private_subnets)
  )
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support
}

################################################################################
# Internet Gateway
################################################################################
resource "aws_internet_gateway" "igw" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc.id
}

################################################################################
# Publiс route tables
################################################################################
resource "aws_route_table" "public" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc.id
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
}

################################################################################
# NAT Gateway
################################################################################
resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  vpc = true
}

resource "aws_nat_gateway" "nat" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  allocation_id = element(aws_eip.nat.*.id, count.index)
  subnet_id     = element(aaws_subnet.public.*.id, count.index)

  depends_on = [aws_internet_gateway.igw]
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
  route_table_id = element(aws_route_table.private.*.id, count.index)
}
