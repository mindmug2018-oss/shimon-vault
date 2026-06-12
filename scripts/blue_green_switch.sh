#!/bin/bash
# scripts/blue_green_switch.sh
#
# Manually shift ALB traffic from blue to green (or green to blue).
# In normal operation this is called automatically by cd.yml.
# Use this script to demo the switch live during the presentation.
#
# Usage:
#   bash scripts/blue_green_switch.sh green    ← shift traffic to green
#   bash scripts/blue_green_switch.sh blue     ← rollback to blue

set -euo pipefail

TARGET="${1:-}"

if [[ "$TARGET" != "blue" && "$TARGET" != "green" ]]; then
  echo "Usage: $0 [blue|green]"
  exit 1
fi

cd "$(dirname "$0")/../terraform"

ALB_ARN=$(terraform output -raw alb_arn 2>/dev/null || \
  aws elbv2 describe-load-balancers \
    --names "shimonvault-alb" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text --region ap-northeast-2)

BLUE_TG_ARN=$(terraform output -raw alb_target_group_blue_arn 2>/dev/null || \
  aws elbv2 describe-target-groups \
    --names "shimonvault-tg-blue" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text --region ap-northeast-2)

GREEN_TG_ARN=$(terraform output -raw alb_target_group_green_arn 2>/dev/null || \
  aws elbv2 describe-target-groups \
    --names "shimonvault-tg-green" \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text --region ap-northeast-2)

# Find the HTTPS (443) listener
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query "Listeners[?Port==\`443\`].ListenerArn" \
  --output text --region ap-northeast-2)

if [[ -z "$LISTENER_ARN" ]]; then
  # Fall back to HTTP 80
  LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`80\`].ListenerArn" \
    --output text --region ap-northeast-2)
fi

echo "════════════════════════════════════════════════"
echo "  ShimonVault — Blue/Green Traffic Switch"
echo "  Direction: → $TARGET"
echo "════════════════════════════════════════════════"
echo ""

if [[ "$TARGET" == "green" ]]; then
  ACTIVE_TG_ARN="$GREEN_TG_ARN"
  ACTIVE_LABEL="green (:green image)"
  STANDBY_LABEL="blue (:blue image)"
else
  ACTIVE_TG_ARN="$BLUE_TG_ARN"
  ACTIVE_LABEL="blue (:blue image)"
  STANDBY_LABEL="green (:green image)"
fi

echo "Before switch: verifying green target group health..."
aws elbv2 describe-target-health \
  --target-group-arn "$GREEN_TG_ARN" \
  --query "TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}" \
  --output table --region ap-northeast-2

echo ""
echo "Switching ALB listener to $TARGET target group..."

# Find the default forward rule
RULE_ARN=$(aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query "Rules[?IsDefault==\`true\`].RuleArn" \
  --output text --region ap-northeast-2)

# Modify the default rule to forward to the chosen target group
aws elbv2 modify-rule \
  --rule-arn "$RULE_ARN" \
  --actions "Type=forward,TargetGroupArn=$ACTIVE_TG_ARN" \
  --region ap-northeast-2 > /dev/null

echo ""
echo "✅ ALB listener updated:"
echo "   Active:  $ACTIVE_LABEL"
echo "   Standby: $STANDBY_LABEL"
echo ""
echo "Verifying — running a quick health check on the live endpoint..."
ALB_DNS=$(terraform output -raw alb_dns_name)
sleep 3

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  "https://$ALB_DNS/health" --max-time 10 --insecure || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  echo "  ✅ /health → 200 — $TARGET environment is serving traffic"
else
  echo "  ⚠️  /health → $HTTP_STATUS — check the $TARGET instance"
fi

echo ""
echo "📊 Check Grafana → AuditStream → deployment event logged"
echo "   Check Slack / Telegram → deployment complete notification"
