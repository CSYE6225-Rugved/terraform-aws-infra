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
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.vpc_name}-public-subnet-${each.key}"
  }
}

resource "aws_subnet" "private" {
  for_each                = { for idx, cidr in var.private_subnet_cidrs : idx => cidr }
  vpc_id                  = aws_vpc.Development.id
  cidr_block              = each.value
  availability_zone       = element(var.availability_zones, each.key)
  map_public_ip_on_launch = false

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
# Create Security Groups
# -----------------------
resource "aws_security_group" "application_sg" {
  vpc_id = aws_vpc.Development.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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

resource "aws_security_group_rule" "allow_app_port" {
  type                     = "ingress"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.load_balancer_security_group.id
  security_group_id        = aws_security_group.application_sg.id
}

# -----------------------
# Create IAM Role for EC2
# -----------------------
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_iam_policy" "ec2_policy" {
  name        = "ec2_policy"
  description = "Policy for EC2 instance to access S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = [
        "arn:aws:s3:::${aws_s3_bucket.webapp_bucket.bucket}",
        "arn:aws:s3:::${aws_s3_bucket.webapp_bucket.bucket}/*"
      ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.db_credentials.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [
          aws_kms_key.secrets_kms_key.arn,
          aws_kms_key.s3_kms_key.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_role_policy_attachment" {
  policy_arn = aws_iam_policy.ec2_policy.arn
  role       = aws_iam_role.ec2_role.name
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.ec2_role.name
}

# -----------------------
# Create S3 Bucket
# -----------------------
resource "random_uuid" "bucket_uuid" {}

resource "aws_s3_bucket" "webapp_bucket" {
  bucket = "myec2-webapp-bucket-${random_uuid.bucket_uuid.result}"

  tags = {
    Name        = "${var.vpc_name}-webapp-bucket"
    Environment = "Dev"
  }
  force_destroy = true

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_kms_key.arn
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "webapp_bucekt_lifecycle" {
  bucket = aws_s3_bucket.webapp_bucket.id

  rule {
    id     = "transition-to-standard-ia"
    status = "Enabled"

    expiration { days = 365 }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
  }
}

# -----------------------
# RDS Setup
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
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "DB security group" }
}

resource "aws_db_parameter_group" "csye6225_db_parameter_group" {
  name        = "csye6225-db-parameter-group"
  family      = var.db_family
  description = "Parameter group for the RDS instance"

  parameter {
    name  = "max_connections"
    value = "150"
  }
}

resource "aws_db_subnet_group" "private" {
  name       = "${lower(replace(var.vpc_name, "[^a-z0-9_-]", "_"))}-private-db-subnet-group"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = { Name = "Private DB Subnet Group" }
}

resource "aws_db_instance" "rdsinstance" {
  identifier             = "csye6225"
  engine                 = "mysql"
  instance_class         = "db.t3.micro"
  db_subnet_group_name   = aws_db_subnet_group.private.name
  parameter_group_name   = aws_db_parameter_group.csye6225_db_parameter_group.name
  multi_az               = false
  publicly_accessible    = false
  username               = var.db_username
  password               = random_password.db_password.result
  db_name                = "csye6225"
  allocated_storage      = 20
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  tags = { Name = "MySQL Database" }
}

# -----------------------
# Create load balancer security group
# -----------------------
resource "aws_security_group" "load_balancer_security_group" {
  name        = "load_balancer_security_group"
  description = "Allow HTTP and HTTPS traffic from the internet"
  vpc_id      = aws_vpc.Development.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "Load Balancer Security Group" }
}

# -----------------------
# Create Launch Template
# -----------------------
resource "aws_launch_template" "asg_template" {
  name_prefix   = "csye6225-asg-template-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  # vpc_security_group_ids = [aws_security_group.application_sg.id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    DB_USER            = var.db_username
    SECRET_NAME        = aws_secretsmanager_secret.db_credentials.name
    AWS_REGION         = var.region
    AWS_S3_BUCKET_NAME = aws_s3_bucket.webapp_bucket.id
    DB_HOST            = replace(aws_db_instance.rdsinstance.endpoint, ":3306", "")
  }))

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.application_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "WebApp Instance from ASG" }
  }
}

# -----------------------
# Create Application Load Balancer
# -----------------------
resource "aws_lb" "web_alb" {
  name               = "webapp-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_security_group.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  tags = { Name = "webapp-alb" }
}
# -----------------------
# Create Target Group and Listener
# -----------------------
resource "aws_lb_target_group" "web_target_group" {
  name        = "webapp-target-group"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.Development.id
  target_type = "instance"

  health_check {
    path                = "/healthz"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_target_group.arn
  }
}

# -----------------------
# Create Auto Scaling Group
# -----------------------
resource "aws_autoscaling_group" "webapp_asg" {
  name                      = "csye6225-asg"
  min_size                  = 1
  max_size                  = 5
  desired_capacity          = 1
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.asg_template.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web_target_group.arn]

  tag {
    key                 = "Name"
    value               = "WebApp-ASG-Instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------
# Create Auto Scaling Policies
# -----------------------
resource "aws_cloudwatch_metric_alarm" "scale_up_alarm" {
  alarm_name          = "cpu-high-${aws_autoscaling_group.webapp_asg.name}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 5
  alarm_description   = "Scale up when CPU > 5%"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webapp_asg.name
  }
  alarm_actions = [aws_autoscaling_policy.scale_up_policy.arn]
}

resource "aws_autoscaling_policy" "scale_up_policy" {
  name                   = "scale-up-policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.webapp_asg.name
}

resource "aws_cloudwatch_metric_alarm" "scale_down_alarm" {
  alarm_name          = "cpu-low-${aws_autoscaling_group.webapp_asg.name}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 3
  alarm_description   = "Scale down when CPU < 3%"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webapp_asg.name
  }
  alarm_actions = [aws_autoscaling_policy.scale_down_policy.arn]
}

resource "aws_autoscaling_policy" "scale_down_policy" {
  name                   = "scale-down-policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.webapp_asg.name
}


# -----------------------
# Route53 Setup
# -----------------------
data "aws_route53_zone" "existing_zone" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "dev" {
  zone_id = data.aws_route53_zone.existing_zone.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.web_alb.dns_name
    zone_id                = aws_lb.web_alb.zone_id
    evaluate_target_health = true
  }
}

# -----------------------
# AWS KMS Keys
# -----------------------

# EC2 KMS Key
resource "aws_kms_key" "ec2_kms_key" {
  description             = "KMS key for EC2 instances"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  rotation_period_in_days = 90 # 90-day rotation period

  tags = {
    Name = "${var.vpc_name}-ec2-kms-key"
  }
}

resource "aws_kms_alias" "ec2_kms_alias" {
  name          = "alias/${var.vpc_name}-ec2-kms"
  target_key_id = aws_kms_key.ec2_kms_key.key_id
}

# RDS KMS Key
resource "aws_kms_key" "rds_kms_key" {
  description             = "KMS key for RDS instances"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  rotation_period_in_days = 90 # 90-day rotation period

  tags = {
    Name = "${var.vpc_name}-rds-kms-key"
  }
}

resource "aws_kms_alias" "rds_kms_alias" {
  name          = "alias/${var.vpc_name}-rds-kms"
  target_key_id = aws_kms_key.rds_kms_key.key_id
}

# S3 KMS Key
resource "aws_kms_key" "s3_kms_key" {
  description             = "KMS key for S3 buckets"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  rotation_period_in_days = 90 # 90-day rotation period

  tags = {
    Name = "${var.vpc_name}-s3-kms-key"
  }
}

resource "aws_kms_alias" "s3_kms_alias" {
  name          = "alias/${var.vpc_name}-s3-kms"
  target_key_id = aws_kms_key.s3_kms_key.key_id
}

# Secrets Manager KMS Key
resource "aws_kms_key" "secrets_kms_key" {
  description             = "KMS key for AWS Secrets Manager"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  rotation_period_in_days = 90 # 90-day rotation period

  tags = {
    Name = "${var.vpc_name}-secrets-kms-key"
  }
}

resource "aws_kms_alias" "secrets_kms_alias" {
  name          = "alias/${var.vpc_name}-secrets-kms"
  target_key_id = aws_kms_key.secrets_kms_key.key_id
}

# -----------------------
# Generate Random DB Password
# -----------------------
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Generate random UUID for secrets
resource "random_uuid" "secrets_uuid" {}

# Database credentials secret
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.vpc_name}-db-credentials-${random_uuid.secrets_uuid.result}"
  kms_key_id              = aws_kms_key.secrets_kms_key.arn
  recovery_window_in_days = 7

  tags = {
    Name = "${var.vpc_name}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials_version" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}
