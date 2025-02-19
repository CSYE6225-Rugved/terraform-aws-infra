terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region  = var.region
  profile = var.profile
}

# Create a VPC
resource "aws_vpc" "Development" {
  cidr_block = var.cidr_block
  tags = {
    Name = var.vpc_name
  }
}

# Create public Subnet
resource "aws_subnet" "public" {
  for_each                = { for idx, cidr in var.public_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.Development.id
  cidr_block              = each.value
  availability_zone       = element(var.availability_zones, each.key)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.vpc_name}-public-subnet-${each.key}"
  }
}

# Create private Subnet
resource "aws_subnet" "private" {
  for_each                = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.Development.id
  cidr_block              = each.value
  availability_zone       = element(var.availability_zones, each.key)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.vpc_name}-private-subnet-${each.key}"
  }
}

# Create Public route table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.Development.id
  tags = {
    Name = "${var.vpc_name}-PublicRouteTable"
  }
}
# Create Private Route Table
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-PrivateRouteTable"
  }
}

# Associate Public Subnets with the Public Route Table
resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public_rt.id
}

# Associate Private Subnets with the Private Route Table
resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private_rt.id
}

# Create an Internet Gateway and attach it to the VPC
resource "aws_internet_gateway" "IGW" {
  vpc_id = aws_vpc.Development.id

  tags = {
    Name = "${var.vpc_name}-IGW"
  }
}

# Add Route to Public Route Table (Route to Internet)
resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.IGW.id
}