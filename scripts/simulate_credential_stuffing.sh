#!/bin/bash
# scripts/simulate_credential_stuffing.sh
#
# Demo script — Act 2 of the presentation
# Fires 200 login attempts with wrong passwords against POST /auth/login
# This triggers the CloudWatch alarm → Lambda block_ip → Slack + Telegram alert
#
# Usage: bash scripts/simulate_credential_stuffing.sh [base_url]
# Example: bash scripts/simulate_credential_stuffing.sh https://shimonvault.cshimomoto.com

set -euo pipefail

BASE_URL="${1:-}"

if [[ -z "$BASE_URL" ]]; then
  # Read from terraform output if not passed as argument
  BASE_URL="https://$(cd "$(dirname "$0")/../terraform" && terraform output -raw alb_dns_name)"
fi

TARGET="$BASE_URL/auth/login"
TOTAL_ATTEMPTS=200
SLEEP_BETWEEN=0.1   # seconds between requests — fast enough to trigger alarm

# Common weak passwords attackers try
PASSWORDS=(
  "password" "123456" "password123" "admin" "letmein"
  "qwerty" "abc123" "monkey" "master" "dragon"
  "111111" "baseball" "iloveyou" "trustno1" "sunshine"
)

echo "════════════════════════════════════════════════"
echo "  ShimonVault — Credential Stuffing Simulation"
echo "  Target: $TARGET"
echo "  Attempts: $TOTAL_ATTEMPTS"
echo "════════════════════════════════════════════════"
echo ""
echo "⚠️  This will trigger a CloudWatch alarm."
echo "   Watch Grafana: login failure rate should spike red."
echo "   Watch Slack + Telegram: alert should arrive in ~2 min."
echo ""
read -r -p "Press Enter to start the attack simulation..."
echo ""

SUCCESS=0
FAILED=0
BLOCKED=0

for i in $(seq 1 $TOTAL_ATTEMPTS); do
  # Pick a random username and password from the lists
  USERNAME="user$(( RANDOM % 50 + 1 ))@example.com"
  PASSWORD="${PASSWORDS[$((RANDOM % ${#PASSWORDS[@]}))]}"

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$TARGET" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
    --max-time 5 || echo "000")

  if [[ "$HTTP_STATUS" == "200" ]]; then
    (( SUCCESS += 1 ))
    echo "[$i/$TOTAL_ATTEMPTS] $USERNAME → ✅ 200 (unexpected success)"
  elif [[ "$HTTP_STATUS" == "429" ]]; then
    (( BLOCKED += 1 ))
    echo "[$i/$TOTAL_ATTEMPTS] $USERNAME → 🚫 429 RATE LIMITED"
  elif [[ "$HTTP_STATUS" == "000" ]]; then
    (( BLOCKED += 1 ))
    echo "[$i/$TOTAL_ATTEMPTS] → 🔴 CONNECTION REFUSED (IP blocked)"
    if (( BLOCKED >= 5 )); then
      echo ""
      echo "  IP is blocked — attack has been detected and stopped."
      break
    fi
  else
    (( FAILED += 1 ))
    printf "[$i/$TOTAL_ATTEMPTS] %-35s → ❌ %s\n" "$USERNAME" "$HTTP_STATUS"
  fi

  sleep "$SLEEP_BETWEEN"
done

echo ""
echo "════════════════════════════════════════════════"
echo "  Attack simulation complete"
echo "  Successful logins:   $SUCCESS"
echo "  Failed attempts:     $FAILED"
echo "  Blocked (rate/IP):   $BLOCKED"
echo "════════════════════════════════════════════════"
echo ""
echo "📊 Now check:"
echo "   Grafana → AuditStream → 'Login failure rate' panel (should be red)"
echo "   Slack / Telegram → credential stuffing alert message"
echo "   DynamoDB → incidents table → new record"
echo "   AWS Console → Security Group → new NACL DENY rule"
