variable "vpc_name" {
  description = "Name for VPC"
  type        = string
}
variable "region" {
  description = "Region"
  type        = string
}

variable "profile" {
  description = "user profile"
  type        = string
}

variable "cidr_block" {
  description = "user profile"
  type        = string
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
}


# EC2 Instance variables
variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
}

variable "instance_type" {
  description = "Instance type for the EC2 instance"
  type        = string
}

variable "app_port" {
  description = "Port on which the application runs"
  type        = number
}
variable "key_name" {
  description = "The name of the SSH key pair to use for EC2"
  type        = string
}

# RDS variables
variable "db_username" {
  description = "Username for the RDS instance"
  type        = string
}
variable "db_password" {
  description = "Password for the RDS instance"
  type        = string
}
variable "db_family" {
  description = "DB family for the RDS instance"
  type        = string
}

variable "domain_name" {
  description = "Your domain name (e.g., example.com)"
  type        = string
}
variable "certificate_arn" {
  description = "The ARN of the ACM certificate for the domain"
  type        = string

}