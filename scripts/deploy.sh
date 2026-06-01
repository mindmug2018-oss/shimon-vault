#!/bin/bash
# ─────────────────────────────────────────────────────────────
# deploy.sh
#
# Run this at the START of each work session.
# It initializes Terraform, applies infrastructure, then
# generates the .env file with current outputs.
#
# Usage: bash scripts/deploy.sh
# ─────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

echo "🚀 ShimonVault — Starting deployment..."
echo ""

cd "$TF_DIR"

echo "1️⃣  terraform init"
terraform init

echo ""
echo "2️⃣  terraform plan (review what will be created)"
terraform plan

echo ""
echo "3️⃣  terraform apply"
terraform apply -auto-approve

echo ""
echo "4️⃣  Generating .env from Terraform outputs"
cd "$REPO_ROOT"
bash scripts/generate_env.sh

echo ""
echo "5️⃣  Updating SSH config"
bash scripts/update_ssh_config.sh

echo ""
echo "✅ Deployment complete!"
echo ""
terraform -chdir="$TF_DIR" output
