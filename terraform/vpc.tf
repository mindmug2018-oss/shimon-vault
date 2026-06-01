# ─────────────────────────────────────────────
# VPC
# ─────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true   # needed for RDS endpoint resolution

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# ─────────────────────────────────────────────
# Subnets
# ─────────────────────────────────────────────

# Public subnet — holds: NAT instance, Bastion, ALB
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true   # instances in this subnet get a public IP

  tags = {
    Name = "${var.project_name}-public-subnet"
    Tier = "public"
  }
}

# Private subnet — holds: App EC2s (blue/green), RDS
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}a"
  # NO map_public_ip — these instances are not directly reachable from internet

  tags = {
    Name = "${var.project_name}-private-subnet"
    Tier = "private"
  }
}

# Second private subnet in a different AZ — required by RDS subnet group
# RDS requires at least 2 AZs even if we only use one (no Multi-AZ)
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "${var.aws_region}c"

  tags = {
    Name = "${var.project_name}-private-subnet-b"
    Tier = "private"
  }
}

# ─────────────────────────────────────────────
# Internet Gateway — the VPC's door to the internet
# (only for the public subnet via the route table below)
# ─────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# ─────────────────────────────────────────────
# Route Tables
# ─────────────────────────────────────────────

# Public route table — all outbound traffic goes to internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Associate the public route table with the public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — outbound internet traffic goes through NAT instance
# The NAT instance route is added in nat_instance.tf after the NAT EC2 is created
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

# Associate private route table with both private subnets
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}
