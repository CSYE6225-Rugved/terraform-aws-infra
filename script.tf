# -----------------------
# Define AWS Provider
# -----------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

# -----------------------
# Create VPC
# -----------------------
resource "aws_vpc" "Development" {
  cidr_block = var.cidr_block

  tags = {
    Name = var.vpc_name
  }
}

# -----------------------
# Create Public & Private Subnets
# -----------------------
resource "aws_subnet" "public" {
  for_each                = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.Development.id
  cidr_block              = each.value
  availability_zone       = element(var.availability_zones, each.key)
  map_public_ip_on_launch = true # Ensure public subnets

  tags = {
    Name = "${var.vpc_name}-public-subnet-${each.key}"
  }
}

resource "aws_subnet" "private" {
  for_each                = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.Development.id
  cidr_block              = each.value
  availability_zone       = element(var.availability_zones, each.key)
  map_public_ip_on_launch = false # Private subnets do not need public IPs

  tags = {
    Name = "${var.vpc_name}-private-subnet-${each.key}"
  }
}

# -----------------------
# Fetch Public Subnets Dynamically
# -----------------------
data "aws_subnets" "public_subnets" {
  filter {
    name   = "vpc-id"
    values = [aws_vpc.Development.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Select the first available public subnet
locals {
  selected_subnet_id = length(data.aws_subnets.public_subnets.ids) > 0 ? tolist(data.aws_subnets.public_subnets.ids)[0] : null
}

# -----------------------
# Create Internet Gateway & Routing
# -----------------------
resource "aws_internet_gateway" "IGW" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-IGW"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-PublicRouteTable"
  }
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-PrivateRouteTable"
  }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.IGW.id
}

resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_rt.id
}

# -----------------------
# Create Security Group
# -----------------------
resource "aws_security_group" "application_sg" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-application-sg"
  }
}

resource "aws_security_group_rule" "allow_ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.application_sg.id
}

resource "aws_security_group_rule" "allow_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.application_sg.id
}

resource "aws_security_group_rule" "allow_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.application_sg.id
}

resource "aws_security_group_rule" "allow_app_port" {
  type              = "ingress"
  from_port         = var.app_port
  to_port           = var.app_port
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.application_sg.id
}

# -----------------------
# Create EC2 Instance
# -----------------------
resource "aws_instance" "web" {
  count                  = local.selected_subnet_id != null ? 1 : 0 # Prevent error if no subnet found
  ami                    = var.ami_id
  key_name               = var.key_name
  instance_type          = var.instance_type
  subnet_id              = local.selected_subnet_id
  vpc_security_group_ids = [aws_security_group.application_sg.id]

  root_block_device {
    volume_size           = 25
    volume_type           = "gp2"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.vpc_name}-web-instance"
  }
}
