#!/bin/bash
# scripts/fetch_docker_certs.sh
set -e

BASTION_IP="$1"
BLUE_IP="$2"
KEY="$HOME/.ssh/id_ed25519_shimonvault"
CERTS_DIR="$HOME/shimon-vault/monitoring/docker-certs"
COMPOSE_FILE="$HOME/shimon-vault/monitoring/docker-compose.yml"
PORTAINER_URL="http://localhost:9000"
PORTAINER_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-shimonvault2026}"

echo "📜 Fetching Docker TLS certs from EC2..."
mkdir -p "$CERTS_DIR"

scp -i "$KEY" \
    -o StrictHostKeyChecking=no \
    -o ProxyJump="ec2-user@${BASTION_IP}" \
    "ec2-user@${BLUE_IP}:/opt/shimonvault/docker-certs/*" \
    "$CERTS_DIR/"
echo "✅ Certs saved to $CERTS_DIR"

TAILSCALE_IP=$(ssh -i "$KEY" \
    -o StrictHostKeyChecking=no \
    -o ProxyJump="ec2-user@${BASTION_IP}" \
    "ec2-user@${BLUE_IP}" \
    "tailscale ip -4 2>/dev/null || echo ''" 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
    echo "⚠️  Could not get Tailscale IP via SSH — trying tailscale status on proj-mgmt..."
    TAILSCALE_IP=$(tailscale status --json 2>/dev/null | python3 -c "
import sys,json
data=json.load(sys.stdin)
for p in (data.get('Peer') or {}).values():
    if 'shimonvault-app' in p.get('HostName','') and p.get('TailscaleIPs'):
        print(p['TailscaleIPs'][0]); break
" 2>/dev/null || echo "")
fi
if [ -z "$TAILSCALE_IP" ]; then
    echo "⚠️  Could not get Tailscale IP from any source — skipping Portainer + Prometheus config"
    exit 0
fi
echo "✅ EC2 Tailscale IP: $TAILSCALE_IP"

# Update Prometheus fastapi-app scrape target with new Tailscale IP
TARGETS_FILE="$(dirname "$0")/../monitoring/prometheus/targets/fastapi_app.json"
cat > "$TARGETS_FILE" << TARGETS_EOF
[
  {
    "targets": [":8000"],
    "labels": {
      "instance": "shimonvault-app-blue",
      "role": "app"
    }
  }
]
TARGETS_EOF
echo "✅ Prometheus fastapi-app target updated → $TAILSCALE_IP:8000"

# Update Prometheus ec2-nodes scrape target with new Tailscale IP
EC2_NODES_FILE="$(dirname "$0")/../monitoring/prometheus/targets/ec2_nodes.json"
cat > "$EC2_NODES_FILE" << NODES_EOF
[
  {
    "targets": [":9100"],
    "labels": {
      "instance": "shimonvault-app-blue",
      "job": "ec2-nodes"
    }
  }
]
NODES_EOF
echo "✅ Prometheus ec2-nodes target updated → $TAILSCALE_IP:9100"
curl -s -X POST http://localhost:9090/-/reload > /dev/null 2>&1 && echo "✅ Prometheus reloaded"

python3 -c "
import re
with open('$COMPOSE_FILE', 'r') as f:
    content = f.read()
content = re.sub(r'DOCKER_HOST:.*', 'DOCKER_HOST: \"tcp://$TAILSCALE_IP:2376\"', content)
content = re.sub(r'--host tcp://[0-9.]+:2376', '--host tcp://$TAILSCALE_IP:2376', content)
with open('$COMPOSE_FILE', 'w') as f:
    f.write(content)
print('✅ docker-compose.yml updated → tcp://$TAILSCALE_IP:2376')
"

# ── Hard reset Portainer ──────────────────────────────────────────────────────
echo "🗑️  Hard resetting Portainer data..."
cd "$(dirname $COMPOSE_FILE)"

docker compose stop portainer 2>/dev/null || true
docker stop shimonvault-portainer 2>/dev/null || true
docker rm shimonvault-portainer 2>/dev/null || true

COMPOSE_DIR=$(basename "$(dirname $COMPOSE_FILE)")
for VOL in \
    "portainer_data" \
    "${COMPOSE_DIR}_portainer_data" \
    "monitoring_portainer_data" \
    "shimonvault_portainer_data" \
    "shimonvault_monitoring_portainer_data"; do
    if docker volume inspect "$VOL" > /dev/null 2>&1; then
        echo "   Removing volume: $VOL"
        docker volume rm "$VOL" 2>/dev/null || true
    fi
done
docker volume ls -q | grep -i portainer | while read VOL; do
    echo "   Removing volume: $VOL"
    docker volume rm "$VOL" 2>/dev/null || true
done
echo "   ✅ All Portainer volumes removed"

echo "🔄 Starting fresh Portainer..."
docker compose up -d portainer
sleep 12

echo "⏳ Waiting for Portainer to initialize..."
for i in $(seq 1 24); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 3 "$PORTAINER_URL/api/system/status" 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ]; then
        echo "   ✅ Portainer API is ready (attempt $i)"
        break
    fi
    echo "   Waiting... ($i/24) HTTP $STATUS"
    sleep 5
done

echo "🔐 Creating admin user: admin / $PORTAINER_PASSWORD"
INIT_HTTP=$(curl -s -o /tmp/portainer_init.json -w "%{http_code}" \
    -X POST "$PORTAINER_URL/api/users/admin/init" \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"admin\",\"Password\":\"$PORTAINER_PASSWORD\"}" 2>/dev/null || echo "000")
echo "   Init response: HTTP $INIT_HTTP"
cat /tmp/portainer_init.json 2>/dev/null && echo ""

if [ "$INIT_HTTP" != "200" ] && [ "$INIT_HTTP" != "204" ]; then
    echo "⚠️  Admin init failed (HTTP $INIT_HTTP)"
    echo "   Open http://localhost:9000 NOW and set password to: $PORTAINER_PASSWORD"
    exit 1
fi
echo "✅ Admin user created"

echo "🔑 Logging in..."
LOGIN_HTTP=$(curl -s -o /tmp/portainer_login.json -w "%{http_code}" \
    -X POST "$PORTAINER_URL/api/auth" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$PORTAINER_PASSWORD\"}" 2>/dev/null || echo "000")
echo "   Login response: HTTP $LOGIN_HTTP"

JWT=$(python3 -c "
import json
try:
    with open('/tmp/portainer_login.json') as f:
        print(json.load(f).get('jwt', ''))
except:
    print('')
" 2>/dev/null || echo "")

if [ -z "$JWT" ]; then
    echo "⚠️  Login failed — check password"
    cat /tmp/portainer_login.json 2>/dev/null
    exit 1
fi
echo "✅ Logged in (JWT obtained)"

# ── Create the Docker environment ─────────────────────────────────────────────
# FIXED: Portainer's POST /api/endpoints expects multipart/form-data, NOT JSON.
# Sending JSON made it ignore the Name field and report "Invalid environment name".
# Here we send form fields with -F, and upload the certs as files (…File fields).
echo "➕ Creating environment: shimonvault-app-blue → tcp://$TAILSCALE_IP:2376"

ENV_HTTP=$(curl -s -o /tmp/portainer_env.json -w "%{http_code}" \
    -X POST "$PORTAINER_URL/api/endpoints" \
    -H "Authorization: Bearer $JWT" \
    -F "Name=shimonvault-app-blue" \
    -F "EndpointCreationType=1" \
    -F "URL=tcp://$TAILSCALE_IP:2376" \
    -F "TLS=true" \
    -F "TLSSkipVerify=false" \
    -F "TLSSkipClientVerify=false" \
    -F "TLSCACertFile=@$CERTS_DIR/ca.pem" \
    -F "TLSCertFile=@$CERTS_DIR/client-cert.pem" \
    -F "TLSKeyFile=@$CERTS_DIR/client-key.pem" \
    2>/dev/null || echo "000")

echo "   Environment create: HTTP $ENV_HTTP"

if [ "$ENV_HTTP" = "200" ] || [ "$ENV_HTTP" = "201" ]; then
    echo "✅ Environment created successfully"
else
    echo "⚠️  Environment create returned HTTP $ENV_HTTP"
    cat /tmp/portainer_env.json 2>/dev/null && echo ""
    echo "   Manual setup:"
    echo "   1. Open http://localhost:9000  login: admin / $PORTAINER_PASSWORD"
    echo "   2. Environments → Add → Docker Standalone → API"
    echo "   3. URL: tcp://$TAILSCALE_IP:2376  TLS: enabled"
    echo "   4. Upload certs from: $CERTS_DIR/"
fi

echo ""
echo "🌐 Portainer: http://localhost:9000"
echo "   Login:       admin / $PORTAINER_PASSWORD"
echo "   Environment: shimonvault-app-blue → tcp://$TAILSCALE_IP:2376"
