variable "project_name" {
  description = "Project name — used as prefix for all AWS resource names"
  type        = string
  default     = "shimonvault"
}

variable "environment" {
  description = "Deployment environment (dev / prod)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy everything into"
  type        = string
  default     = "ap-northeast-2"  # Seoul
}

variable "vpc_cidr" {
  description = "CIDR block for the entire VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT instance, Bastion, ALB)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (App EC2s, RDS)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "your_ip_cidr" {
  description = "Your home/office IP in CIDR notation (e.g. 1.2.3.4/32). Used to allow SSH to Bastion only from your IP."
  type        = string
  # Set this in terraform.tfvars — run 'curl ifconfig.me' to find your IP
}

variable "key_pair_name" {
  description = "Name of the EC2 Key Pair to use for SSH access"
  type        = string
  default     = "shimonvault-key"
}

variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
  default     = "shimonvault"
}

variable "db_username" {
  description = "PostgreSQL master username"
  type        = string
  default     = "shimonvault"
}

variable "db_password" {
  description = "PostgreSQL master password — never hardcode, set in terraform.tfvars"
  type        = string
  sensitive   = true  # never printed in terraform plan output
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for EC2 instances to join your Tailnet"
  type        = string
  sensitive   = true
}

variable "dockerhub_username" {
  description = "Docker Hub username for pulling images"
  type        = string
}

variable "app_image_tag" {
  description = "Docker image tag to deploy (e.g. latest, or a git SHA)"
  type        = string
  default     = "latest"
}

variable "onprem_tailscale_ip" {
  description = "Tailscale IP of your on-prem Linux server (starts with 100.x.x.x)"
  type        = string
}
