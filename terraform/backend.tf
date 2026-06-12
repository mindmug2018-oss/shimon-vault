# ─────────────────────────────────────────────────────────────────────────────
# terraform/backend.tf — Remote State Bootstrap Documentation
#
# The actual backend "s3" block is in main.tf (Terraform requires it there).
# This file documents the ONE-TIME manual commands you must run BEFORE
# the first `terraform init` to create the state bucket and lock table.
#
# Run these commands exactly ONCE from your terminal. Never run again.
# These two resources are NEVER managed by Terraform so destroy never deletes them.
# ─────────────────────────────────────────────────────────────────────────────
#
# STEP 1 — Get your AWS Account ID:
#   aws sts get-caller-identity --query Account --output text
#   → e.g. 123456789012
#   Replace every occurrence of REPLACE_WITH_YOUR_ACCOUNT_ID below and in main.tf.
#
# STEP 2 — Create the S3 state bucket:
#   aws s3 mb s3://shimonvault-tfstate-123456789012 --region ap-northeast-2
#
# STEP 3 — Enable versioning on the state bucket (lets you roll back bad state):
#   aws s3api put-bucket-versioning \
#     --bucket shimonvault-tfstate-123456789012 \
#     --versioning-configuration Status=Enabled
#
# STEP 4 — Block all public access on the state bucket:
#   aws s3api put-public-access-block \
#     --bucket shimonvault-tfstate-123456789012 \
#     --public-access-block-configuration \
#       "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
#
# STEP 5 — Create the DynamoDB lock table:
#   aws dynamodb create-table \
#     --table-name shimonvault-tfstate-lock \
#     --attribute-definitions AttributeName=LockID,AttributeType=S \
#     --key-schema AttributeName=LockID,KeyType=HASH \
#     --billing-mode PAY_PER_REQUEST \
#     --region ap-northeast-2
#
# STEP 6 — Update main.tf backend block:
#   Replace "shimonvault-tfstate-REPLACE_WITH_YOUR_ACCOUNT_ID"
#   with    "shimonvault-tfstate-123456789012"   (your real account ID)
#
# STEP 7 — Now run:
#   terraform init
#   terraform plan
#   terraform apply -auto-approve
# ─────────────────────────────────────────────────────────────────────────────
