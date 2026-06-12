#!/bin/bash
# scripts/simulate_access_control.sh
#
# Demo script — Act 3 of the presentation
# A viewer account tries to access admin-only endpoints.
# Expected results:
#   - 403 on every request
#   - After 5 attempts: account is temporarily suspended
#   - Incidents written to DynamoDB
#   - Slack + Telegram alert
#
# Usage: bash scripts/simulate_access_control.sh [base_url]

set -euo pipefail

BASE_URL="${1:-}"

if [[ -z "$BASE_URL" ]]; then
  BASE_URL="https://$(cd "$(dirname "$0")/../terraform" && terraform output -raw alb_dns_name)"
fi

echo "════════════════════════════════════════════════"
echo "  ShimonVault — Broken Access Control Simulation"
echo "  Target: $BASE_URL"
echo "════════════════════════════════════════════════"
echo ""
echo "Step 1: Log in as a VIEWER (low privilege account)..."

# ── Login as viewer ───────────────────────────────────────────────────────────
VIEWER_TOKEN=$(curl -s -X POST "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"viewer@shimonvault.internal","password":"viewer-demo-123"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token','FAILED'))")

if [[ "$VIEWER_TOKEN" == "FAILED" || -z "$VIEWER_TOKEN" ]]; then
  echo "  ❌ Login failed. Is the app running? Check: $BASE_URL/health"
  exit 1
fi

echo "  ✅ Logged in as viewer"
echo "  Token: ${VIEWER_TOKEN:0:40}..."
echo ""
echo "Step 2: Attempt to access ADMIN-ONLY endpoints with viewer token..."
echo ""

# Admin-only endpoints the viewer should NOT be able to reach
ADMIN_ENDPOINTS=(
  "GET /audit/incidents"
  "GET /audit/feed"
  "DELETE /docs/doc-admin-001"
  "DELETE /docs/doc-admin-002"
  "GET /docs/doc-admin-003/versions"
  "DELETE /meetings/mtg-admin-001"
)

ATTEMPT=0
FORBIDDEN=0
UNEXPECTED=0

for endpoint in "${ADMIN_ENDPOINTS[@]}"; do
  METHOD=$(echo "$endpoint" | cut -d' ' -f1)
  PATH=$(echo "$endpoint" | cut -d' ' -f2)
  (( ATTEMPT += 1 ))

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X "$METHOD" "$BASE_URL$PATH" \
    -H "Authorization: Bearer $VIEWER_TOKEN" \
    --max-time 5 || echo "000")

  if [[ "$HTTP_STATUS" == "403" ]]; then
    (( FORBIDDEN += 1 ))
    printf "  [%d] %-38s → 🔒 403 Forbidden ✅ (correct)\n" "$ATTEMPT" "$METHOD $PATH"
  elif [[ "$HTTP_STATUS" == "401" ]]; then
    printf "  [%d] %-38s → 🔑 401 Unauthorized\n" "$ATTEMPT" "$METHOD $PATH"
  else
    (( UNEXPECTED += 1 ))
    printf "  [%d] %-38s → ⚠️  %s (unexpected!)\n" "$ATTEMPT" "$METHOD $PATH" "$HTTP_STATUS"
  fi

  sleep 0.3
done

echo ""
echo "════════════════════════════════════════════════"
echo "  Access control test complete"
echo "  Attempts:             $ATTEMPT"
echo "  Correctly blocked:    $FORBIDDEN"
echo "  Unexpected responses: $UNEXPECTED"
echo "════════════════════════════════════════════════"
echo ""

if [[ $ATTEMPT -ge 5 ]]; then
  echo "🚨 5+ violations triggered — viewer account should be suspended."
  echo "   Checking account status..."
  sleep 1

  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X GET "$BASE_URL/docs/list" \
    -H "Authorization: Bearer $VIEWER_TOKEN" \
    --max-time 5 || echo "000")

  if [[ "$STATUS" == "403" ]]; then
    echo "  ✅ Account suspended — further requests return 403"
  else
    echo "  ⚠️  Status: $STATUS — check suspension logic in auth.py"
  fi
fi

echo ""
echo "📊 Now check:"
echo "   Grafana → AuditStream → 'Blocked access attempts' panel"
echo "   Slack / Telegram → access violation alert message"
echo "   DynamoDB → incidents table → new access_control records"
