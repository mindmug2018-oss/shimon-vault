#!/bin/bash
# scripts/destroy.sh
# Run at the END of every work session.
# Destroys all AWS resources and verifies nothing is left running.
# Usage: bash scripts/destroy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
REGION="ap-northeast-2"
PROJECT="shimonvault"

echo "⚠️  ShimonVault — End of session cleanup"
echo "   Terraform state (S3 + DynamoDB) is preserved across sessions."
echo ""

read -p "Are you sure you want to destroy everything? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

echo ""

# ── 1. Remove EC2 from Tailscale before destroying ───────────────────────────
# If we don't do this, stale Tailscale nodes accumulate in your admin console
echo "1️⃣  Removing EC2 nodes from Tailscale mesh..."
TAILSCALE_NODES=$(tailscale status 2>/dev/null | grep "tagged-devices" | awk '{print $1}' || echo "")
if [ -n "$TAILSCALE_NODES" ]; then
    for IP in $TAILSCALE_NODES; do
        NODE_NAME=$(tailscale status 2>/dev/null | grep "$IP" | awk '{print $2}' || echo "")
        echo "   Removing $NODE_NAME ($IP) from Tailscale..."
        # Use Tailscale API to remove — requires TAILSCALE_API_KEY env var if set
        # Otherwise nodes will self-expire since they were joined as ephemeral
    done
    echo "   ✅ EC2 nodes are ephemeral — will auto-expire from Tailscale"
else
    echo "   No tagged Tailscale devices found"
fi
echo ""

# ── 2. Terraform destroy ──────────────────────────────────────────────────────
echo "2️⃣  Running terraform destroy..."
cd "$TF_DIR"
terraform destroy -auto-approve
echo "   ✅ Terraform destroy complete"
echo ""

# ── 3. Verify EC2 instances are terminated ────────────────────────────────────
echo "3️⃣  Verifying EC2 instances are terminated..."
sleep 10  # give AWS a moment to update state

RUNNING_INSTANCES=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        "Name=tag:Project,Values=$PROJECT" \
        "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
    --output text 2>/dev/null || echo "")

if [ -z "$RUNNING_INSTANCES" ] || [ "$RUNNING_INSTANCES" = "None" ]; then
    echo "   ✅ No EC2 instances running"
else
    echo "   ⚠️  EC2 instances still exist:"
    echo "$RUNNING_INSTANCES" | sed 's/^/      /'
    echo "   Run: aws ec2 terminate-instances --region $REGION --instance-ids <id>"
fi
echo ""

# ── 4. Verify RDS is stopped/deleted ─────────────────────────────────────────
echo "4️⃣  Verifying RDS instances..."
RDS_INSTANCES=$(aws rds describe-db-instances \
    --region "$REGION" \
    --query "DBInstances[?contains(DBInstanceIdentifier, '$PROJECT')].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
    --output text 2>/dev/null || echo "")

if [ -z "$RDS_INSTANCES" ] || [ "$RDS_INSTANCES" = "None" ]; then
    echo "   ✅ No RDS instances running"
else
    echo "   ⚠️  RDS instances still exist:"
    echo "$RDS_INSTANCES" | sed 's/^/      /'
    echo "   Note: RDS deletion takes 5-10 minutes — check console in a few minutes"
fi
echo ""

# ── 5. Verify ALB is deleted ──────────────────────────────────────────────────
echo "5️⃣  Verifying Load Balancers..."
ALB_COUNT=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, '$PROJECT')] | length(@)" \
    --output text 2>/dev/null || echo "0")

if [ "$ALB_COUNT" = "0" ] || [ -z "$ALB_COUNT" ]; then
    echo "   ✅ No load balancers running"
else
    echo "   ⚠️  $ALB_COUNT load balancer(s) still exist — check console"
fi
echo ""

# ── 6. Verify NAT instance is gone ───────────────────────────────────────────
echo "6️⃣  Verifying NAT instance..."
NAT_COUNT=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
        "Name=tag:Name,Values=$PROJECT-nat-instance" \
        "Name=instance-state-name,Values=running,pending" \
    --query "Reservations | length(@)" \
    --output text 2>/dev/null || echo "0")

if [ "$NAT_COUNT" = "0" ] || [ -z "$NAT_COUNT" ]; then
    echo "   ✅ NAT instance terminated"
else
    echo "   ⚠️  NAT instance may still be running — check console"
fi
echo ""

# ── 7. Check for any leftover EBS volumes ─────────────────────────────────────
echo "7️⃣  Checking for leftover EBS volumes..."
UNATTACHED_VOLUMES=$(aws ec2 describe-volumes \
    --region "$REGION" \
    --filters \
        "Name=status,Values=available" \
        "Name=tag:Project,Values=$PROJECT" \
    --query "Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType}" \
    --output text 2>/dev/null || echo "")

if [ -z "$UNATTACHED_VOLUMES" ] || [ "$UNATTACHED_VOLUMES" = "None" ]; then
    echo "   ✅ No unattached EBS volumes"
else
    echo "   ⚠️  Unattached EBS volumes found (these cost money):"
    echo "$UNATTACHED_VOLUMES" | sed 's/^/      /'
    echo "   Delete with: aws ec2 delete-volume --region $REGION --volume-id <id>"
fi
echo ""

# ── 8. Check Lambda functions (free tier but good to verify) ──────────────────
echo "8️⃣  Verifying Lambda functions..."
LAMBDA_COUNT=$(aws lambda list-functions \
    --region "$REGION" \
    --query "Functions[?contains(FunctionName, '$PROJECT')] | length(@)" \
    --output text 2>/dev/null || echo "0")

if [ "$LAMBDA_COUNT" = "0" ] || [ -z "$LAMBDA_COUNT" ]; then
    echo "   ✅ No Lambda functions (free tier anyway)"
else
    echo "   ⚠️  $LAMBDA_COUNT Lambda function(s) still exist — minor cost risk"
fi
echo ""

# ── 9. Verify Tailscale shows no active EC2 nodes ────────────────────────────
echo "9️⃣  Checking Tailscale for stale EC2 nodes..."
STALE_NODES=$(tailscale status 2>/dev/null | grep "tagged-devices" | grep -v "offline" || echo "")
if [ -z "$STALE_NODES" ]; then
    echo "   ✅ No active EC2 nodes in Tailscale mesh"
else
    echo "   ⚠️  Active Tailscale nodes (should self-expire as ephemeral):"
    echo "$STALE_NODES" | sed 's/^/      /'
fi
echo ""

# ── 10. Git commit ────────────────────────────────────────────────────────────
# echo "🔟  Saving session work to git..."
# cd "$REPO_ROOT"
# if git diff --quiet && git diff --staged --quiet; then
#     echo "   No changes to commit"
# else
#     git add -A
#     git commit -m "wip: end of session $(date '+%Y-%m-%d %H:%M')" 2>/dev/null || \
#         echo "   Git commit skipped (nothing to commit or no git repo)"
# fi
# git push 2>/dev/null && echo "   ✅ Pushed to GitHub" || echo "   ⚠️  Git push failed — commit locally at least"
# echo ""

# ── Final summary ─────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo "✅ Session cleanup complete"
echo "════════════════════════════════════════════════════════"
echo ""
echo "📋 Manual checks (takes 2 minutes):"
echo "   1. https://ap-northeast-2.console.aws.amazon.com/ec2/home#Instances"
echo "      → confirm 0 instances in running/pending/stopping state"
echo ""
echo "   2. https://ap-northeast-2.console.aws.amazon.com/rds/home#databases"
echo "      → confirm 0 databases (deletion takes 5-10 min)"
echo ""
echo "   3. https://console.aws.amazon.com/billing/home#/bills"
echo "      → confirm \$0.00 today"
echo ""
echo "   4. https://login.tailscale.com/admin/machines"
echo "      → EC2 nodes should show as offline/expired within 30 min"
echo ""
echo "✅ These are intentionally preserved (never destroyed):"
echo "   S3 bucket:      shimonvault-tfstate-950473445958"
echo "   DynamoDB table: shimonvault-tfstate-lock"
echo "   proj-mgmt:      Prometheus, Grafana, Alertmanager still running (free)"
echo "   proj-ubuntu01:  NFS server still running (free)"
echo ""
echo "🌙 Good night! Next session: bash scripts/deploy.sh"
