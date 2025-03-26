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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow all outbound traffic
  }
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
# Create IAM Role for EC2
# -----------------------
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_role.name
}

# -----------------------
# Create IAM Policy for EC2
# -----------------------
resource "aws_iam_policy" "ec2_policy" {
  name        = "ec2_policy"
  description = "Policy for EC2 instance to access S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${aws_s3_bucket.webapp_bucket.bucket}",
          "arn:aws:s3:::${aws_s3_bucket.webapp_bucket.bucket}/*"
        ]
      },
    ]
  })
}

# -----------------------
# Attach Policy to IAM Role
# -----------------------
resource "aws_iam_role_policy_attachment" "ec2_role_policy_attachment" {
  policy_arn = aws_iam_policy.ec2_policy.arn
  role       = aws_iam_role.ec2_role.name
}
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.ec2_role.name
}
# -----------------------
# Create EC2 Instance with IAM Role
# -----------------------
resource "aws_instance" "web" {
  ami                    = var.ami_id
  key_name               = var.key_name
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.application_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance_profile.name

  root_block_device {
    volume_size           = 25
    volume_type           = "gp2"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    DB_USER            = var.db_username
    DB_PASSWORD        = var.db_password
    AWS_REGION         = var.region
    AWS_S3_BUCKET_NAME = aws_s3_bucket.webapp_bucket.id
    DB_HOST            = replace(aws_db_instance.rdsinstance.endpoint, ":3306", "")
  })

  tags = {
    Name = "${var.vpc_name}-web-instance"
  }
}

# -----------------------
# Create S3 Bucket
# -----------------------

# S3 Bucket
resource "random_uuid" "bucket_uuid" {}

resource "aws_s3_bucket" "webapp_bucket" {
  bucket = "myec2-webapp-bucket-${random_uuid.bucket_uuid.result}"

  tags = {
    Name        = "${var.vpc_name}-webapp-bucket"
    Environment = "Dev"
  }
  force_destroy = true # to delete non-empty bucket

  # Enable default encryption using AES-256
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

# S3 Bucket Lifecycle Configuration
resource "aws_s3_bucket_lifecycle_configuration" "webapp_bucekt_lifecycle" {
  bucket = aws_s3_bucket.webapp_bucket.id

  rule {
    id     = "transition-to-standard-ia"
    status = "Enabled"

    expiration {
      days = 365
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# -----------------------
# Create DB security Group
# -----------------------

resource "aws_security_group" "db_sg" {
  name        = "database security group"
  description = "Allow mysql database access from application group"
  vpc_id      = aws_vpc.Development.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.application_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow all outbound traffic
  }

  tags = {
    Name = "DB security group"
  }
}

# -----------------------
# Create RDS parameter group
# -----------------------
resource "aws_db_parameter_group" "csye6225_db_parameter_group" {
  name        = "csye6225-db-parameter-group"
  family      = var.db_family
  description = "Parameter group for the RDS instance"

  parameter {
    name  = "max_connections"
    value = "150"
  }
}
# -----------------------
# Create DB RDS instance
# -----------------------
resource "aws_db_subnet_group" "private" {
  name       = "${lower(replace(var.vpc_name, "[^a-z0-9_-]", "_"))}-private-db-subnet-group"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "Private DB Subnet Group"
  }
}

resource "aws_db_instance" "rdsinstance" {
  identifier           = "csye6225"
  engine               = "mysql"
  instance_class       = "db.t3.micro"
  db_subnet_group_name = aws_db_subnet_group.private.name
  parameter_group_name = aws_db_parameter_group.csye6225_db_parameter_group.name
  multi_az             = false
  publicly_accessible  = false
  username             = var.db_username
  password             = var.db_password
  db_name              = "csye6225"
  allocated_storage    = 20
  skip_final_snapshot  = true

  vpc_security_group_ids = [aws_security_group.db_sg.id]

  tags = {
    Name = "MySQL Database"
  }
}