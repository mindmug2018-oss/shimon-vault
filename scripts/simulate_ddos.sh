#!/bin/bash
# scripts/simulate_ddos.sh
#
# Demo script — Act 5 of the presentation
# Fires 500 concurrent requests to trigger:
#   1. CPU spike > 80% on the app instance
#   2. CloudWatch alarm → SNS → Slack + Telegram
#   3. ASG scale-out: 1 instance → 2 instances
#   4. ALB distributes load across both instances
#   5. Load drops → ASG scales back to 1 instance
#
# Uses 'hey' (fast HTTP load generator). Install:
#   brew install hey              (Mac)
#   go install github.com/rakyll/hey@latest   (Linux)
#
# Usage: bash scripts/simulate_ddos.sh [base_url]

set -euo pipefail

BASE_URL="${1:-}"

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="https://$(cd "$(dirname "$0")/../terraform" && terraform output -raw alb_dns_name)"
fi

TARGET="$BASE_URL/health"    # hit /health — doesn't require auth, shows ALB working

# ── Check for load testing tool ──────────────────────────────────────────────
if command -v hey &> /dev/null; then
  LOAD_TOOL="hey"
elif command -v ab &> /dev/null; then
  LOAD_TOOL="ab"
else
  echo "❌ Neither 'hey' nor 'ab' (Apache Bench) found."
  echo "   Install hey: brew install hey"
  echo "   Install ab:  sudo apt install apache2-utils"
  exit 1
fi

echo "════════════════════════════════════════════════"
echo "  ShimonVault — DDoS / Traffic Flood Simulation"
echo "  Target: $TARGET"
echo "  Tool:   $LOAD_TOOL"
echo "════════════════════════════════════════════════"
echo ""
echo "This will spike CPU on the app EC2 instance."
echo "CloudWatch alarm fires at >80% CPU for 2 minutes."
echo "ASG will launch a second t3.micro instance."
echo ""
echo "⚠️  Watch:"
echo "   1. Grafana → 'API request rate' panel spikes"
echo "   2. Grafana → 'Instance count' increments from 1 to 2"
echo "   3. Slack/Telegram: HIGH CPU and scale-out notifications"
echo "   4. Wait ~5 minutes after load stops: count drops back to 1"
echo ""
read -r -p "Press Enter to start the load test..."
echo ""

# ── Phase 1: Initial burst (500 concurrent, 2000 total) ─────────────────────
echo "Phase 1: Initial burst (500 concurrent requests)..."
if [[ "$LOAD_TOOL" == "hey" ]]; then
  hey -n 2000 -c 500 -t 30 "$TARGET" || true
else
  ab -n 2000 -c 500 -t 30 "$TARGET" || true
fi

echo ""
echo "Phase 1 complete. Waiting 30 seconds..."
sleep 30

# ── Phase 2: Sustained load (200 concurrent for 3 minutes) ───────────────────
echo "Phase 2: Sustained load (200 concurrent, 3 minutes)..."
if [[ "$LOAD_TOOL" == "hey" ]]; then
  hey -z 3m -c 200 -t 30 "$TARGET" || true
else
  # ab doesn't support duration — approximate with large count
  ab -n 36000 -c 200 -t 180 "$TARGET" || true
fi

echo ""
echo "════════════════════════════════════════════════"
echo "  Load test complete — watching for scale-out..."
echo "════════════════════════════════════════════════"
echo ""
echo "CloudWatch alarm takes ~2 minutes to fire after CPU spikes."
echo "ASG typically takes 2-3 minutes to launch the new instance."
echo ""
echo "Waiting 3 minutes then checking instance count..."
echo "(Keep Grafana open — instance count panel should show 2)"
echo ""

for i in $(seq 1 18); do
  printf "  %d/18 (%d min %d sec remaining)...\r" "$i" $(( (18-i)/6 )) $(( (18-i) % 6 * 10 ))
  sleep 10
done

echo ""
echo "📊 Checking current running instances..."
INSTANCE_COUNT=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=ShimonVault" \
    "Name=instance-state-name,Values=running" \
  --query "length(Reservations[].Instances[])" \
  --output text \
  --region ap-northeast-2 2>/dev/null || echo "N/A")

echo "  Running ShimonVault instances: $INSTANCE_COUNT"
echo ""
echo "📊 Now check:"
echo "   Grafana → Infrastructure Health → 'Instance count' (should be 2)"
echo "   AWS Console → EC2 → Auto Scaling Groups → Activity"
echo "   Slack / Telegram → HIGH CPU alert + scale-out notification"
echo ""
echo "Load is now stopped. ASG should scale back to 1 in ~10 minutes."
