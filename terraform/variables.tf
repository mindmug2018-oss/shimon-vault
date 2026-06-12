# terraform/variables.tf — All input variables
#
# Actual values go in terraform.tfvars (gitignored).
# terraform.tfvars.example contains placeholder values for documentation.
# Sensitive variables are marked sensitive = true so they never appear
# in terraform plan output.

# ─── Core ─────────────────────────────────────────────────────────────────────

variable "project_name" {
  type        = string
  description = "Project name — used as prefix for all AWS resource names"
  default     = "shimonvault"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev / prod)"
  default     = "dev"
}

variable "aws_region" {
  type        = string
  description = "AWS region. ap-northeast-2 = Seoul."
  default     = "ap-northeast-2"
}

# ─── Networking ───────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the entire VPC"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "CIDR for the public subnet (NAT instance, Bastion, ALB)"
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type        = string
  description = "CIDR for the private subnet (App EC2s, RDS)"
  default     = "10.0.2.0/24"
}

variable "your_ip_cidr" {
  type        = string
  description = "Your current public IP in CIDR notation for bastion SSH. Example: 203.0.113.42/32"
}

# ─── Compute ──────────────────────────────────────────────────────────────────

variable "key_pair_name" {
  type        = string
  description = "Name of the EC2 key pair for SSH access"
  default     = "shimonvault-key"
}

# ─── Database ─────────────────────────────────────────────────────────────────

variable "db_name" {
  type        = string
  description = "PostgreSQL database name"
  default     = "shimonvault"
}

variable "db_username" {
  type        = string
  description = "PostgreSQL master username"
  default     = "shimonvault"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "PostgreSQL master password. Set in terraform.tfvars (gitignored)."
}

# ─── Tailscale ────────────────────────────────────────────────────────────────

variable "tailscale_auth_key" {
  type        = string
  sensitive   = true
  description = "Tailscale auth key for EC2 instances to join your Tailnet"
}

variable "onprem_tailscale_ip" {
  type        = string
  description = "Tailscale IP of your on-prem Linux server (starts with 100.x.x.x)"
}

# ─── Docker ───────────────────────────────────────────────────────────────────

variable "dockerhub_username" {
  type        = string
  description = "Docker Hub username for pulling images"
  default     = "mindmug"
}

variable "docker_image" {
  type        = string
  description = "Docker Hub image path (without tag)"
  default     = "mindmug/shimonvault-app"
}

variable "app_image_tag" {
  type        = string
  description = "Docker image tag to deploy (e.g. latest, or a git SHA)"
  default     = "latest"
}

# ─── Auth ─────────────────────────────────────────────────────────────────────

variable "jwt_secret_key" {
  type        = string
  sensitive   = true
  description = "JWT signing secret. Generate: python3 -c \"import secrets; print(secrets.token_hex(32))\""
}

# ─── Notifications ────────────────────────────────────────────────────────────

variable "slack_webhook_url" {
  type        = string
  sensitive   = true
  description = "Slack incoming webhook URL"
}

variable "telegram_bot_token" {
  type        = string
  sensitive   = true
  description = "Telegram bot token from @BotFather"
}

variable "telegram_chat_id" {
  type        = string
  sensitive   = true
  description = "Telegram chat ID to send notifications to"
}

variable "alert_email" {
  type        = string
  description = "Email address for SNS alert subscriptions"
}

# ─── Networking IDs (set by vpc.tf and security_groups.tf outputs) ────────────
# These are passed in via terraform.tfvars after vpc/sg resources are created,
# OR referenced directly as resource attributes within the same root module.
# Declared here so asg.tf, alb.tf etc. can reference them via var.*

variable "vpc_id" {
  type        = string
  description = "VPC ID — output from vpc.tf"
  default     = ""
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "List of public subnet IDs for ALB and NAT instance"
  default     = []
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "List of private subnet IDs for app EC2 and RDS"
  default     = []
}

variable "alb_security_group_id" {
  type        = string
  description = "Security group ID for the ALB"
  default     = ""
}

variable "app_security_group_id" {
  type        = string
  description = "Security group ID for app EC2 instances"
  default     = ""
}

variable "rds_security_group_id" {
  type        = string
  description = "Security group ID for RDS"
  default     = ""
}

variable "app_instance_role_name" {
  type        = string
  description = "IAM role name for EC2 instance profile (defined in iam.tf)"
  default     = ""
}

variable "dockerhub_token" {
  type        = string
  sensitive   = true
  description = "Docker Hub access token for pulling images on EC2 boot"
}
