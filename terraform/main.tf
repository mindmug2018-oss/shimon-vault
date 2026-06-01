terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — this S3 bucket and DynamoDB table must be created
  # manually ONCE before running terraform init.
  # They are never destroyed — they are your project's memory.
  backend "s3" {
    bucket         = "shimonvault-tfstate-950473445958"
    key            = "shimonvault/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "shimonvault-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ─────────────────────────────────────────────
# Data sources — always look up, never hardcode
# ─────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Latest Amazon Linux 2023 AMI (x86_64)
# This automatically picks the newest AMI so you don't hardcode an AMI ID
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  region       = data.aws_region.current.name
  project      = var.project_name
  common_tags  = {
    Project = var.project_name
  }
}
