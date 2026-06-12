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

# Get EC2 Tailscale IP
TAILSCALE_IP=$(ssh -i "$KEY" \
    -o StrictHostKeyChecking=no \
    -o ProxyJump="ec2-user@${BASTION_IP}" \
    "ec2-user@${BLUE_IP}" \
    "tailscale ip -4 2>/dev/null || echo ''" 2>/dev/null || echo "")

if [ -z "$TAILSCALE_IP" ]; then
    echo "⚠️  Could not get Tailscale IP — skipping Portainer config"
    exit 0
fi
echo "✅ EC2 Tailscale IP: $TAILSCALE_IP"

# Update docker-compose.yml with new Tailscale IP
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

# ── Hard reset Portainer — find and remove ALL portainer volumes ──────────────
echo "🗑️  Hard resetting Portainer data..."
cd "$(dirname $COMPOSE_FILE)"

# Stop Portainer container first
docker compose stop portainer 2>/dev/null || true
docker stop shimonvault-portainer 2>/dev/null || true
docker rm shimonvault-portainer 2>/dev/null || true

# Find and remove every volume that could be the Portainer data volume
# Docker Compose names volumes as: <project>_<volume_name>
# The project name is the directory name of the compose file
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

# Also remove any volume with portainer in the name
docker volume ls -q | grep -i portainer | while read VOL; do
    echo "   Removing volume: $VOL"
    docker volume rm "$VOL" 2>/dev/null || true
done

echo "   ✅ All Portainer volumes removed"

# Start fresh Portainer
echo "🔄 Starting fresh Portainer..."
docker compose up -d portainer
sleep 12

# Wait for Portainer API to be ready
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

# Initialize admin user on fresh Portainer
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
    echo "   You have 5 minutes before Portainer times out"
    echo "   Then re-run: bash scripts/fetch_docker_certs.sh $BASTION_IP $BLUE_IP"
    exit 1
fi
echo "✅ Admin user created"

# Login to get JWT
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

# Create the Docker environment with TLS certs as base64 in JSON
echo "➕ Creating environment: shimonvault-app-blue → tcp://$TAILSCALE_IP:2376"

# base64 -w0 is Linux; macOS uses base64 without -w0
CA_CERT=$(base64 -w0 "$CERTS_DIR/ca.pem" 2>/dev/null || base64 "$CERTS_DIR/ca.pem" | tr -d '\n')
CLIENT_CERT=$(base64 -w0 "$CERTS_DIR/client-cert.pem" 2>/dev/null || base64 "$CERTS_DIR/client-cert.pem" | tr -d '\n')
CLIENT_KEY=$(base64 -w0 "$CERTS_DIR/client-key.pem" 2>/dev/null || base64 "$CERTS_DIR/client-key.pem" | tr -d '\n')

ENV_HTTP=$(curl -s -o /tmp/portainer_env.json -w "%{http_code}" \
    -X POST "$PORTAINER_URL/api/endpoints" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d "{
        \"Name\": \"shimonvault-app-blue\",
        \"EndpointCreationType\": 1,
        \"URL\": \"tcp://$TAILSCALE_IP:2376\",
        \"TLS\": true,
        \"TLSSkipVerify\": false,
        \"TLSSkipClientVerify\": false,
        \"TLSCACert\": \"$CA_CERT\",
        \"TLSCert\": \"$CLIENT_CERT\",
        \"TLSKey\": \"$CLIENT_KEY\"
    }" 2>/dev/null || echo "000")

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
