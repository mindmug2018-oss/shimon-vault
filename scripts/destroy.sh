#!/bin/bash
# ─────────────────────────────────────────────────────────────
# destroy.sh
#
# Run this at the END of every work session.
# Destroys all AWS resources to avoid charges.
#
# ⚠️  IMPORTANT: After destroy, check AWS Console to confirm
# 0 running instances and $0.00 on Billing dashboard.
#
# Usage: bash scripts/destroy.sh
# ─────────────────────────────────────────────────────────────

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

echo "⚠️  ShimonVault — Destroying all AWS resources"
echo "   (tfstate S3 bucket and DynamoDB lock table are preserved)"
echo ""

cd "$TF_DIR"

read -p "Are you sure you want to destroy everything? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

terraform destroy -auto-approve

echo ""
echo "✅ Destroy complete."
echo ""
echo "📋 CHECKLIST before closing your laptop:"
echo "   [ ] Go to EC2 Console → confirm 0 running instances"
echo "   [ ] Go to RDS Console → confirm 0 running databases"
echo "   [ ] Go to AWS Billing → confirm \$0.00 today"
echo "   [ ] git add . && git commit -m 'wip: end of session'"
echo ""
echo "   The S3 tfstate bucket and DynamoDB lock table are intentionally"
echo "   preserved — they are never destroyed (they are your project's memory)."
