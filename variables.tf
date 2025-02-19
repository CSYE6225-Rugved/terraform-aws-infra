variable "vpc_name" {
  description = "Name for VPC"
  type        = string
}
variable "region" {
  description = "Region"
  type        = string
}

variable "profile" 
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