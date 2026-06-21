#!/bin/bash
# terraform/templates/app_user_data.sh.tpl
set -euo pipefail
exec > /var/log/user_data.log 2>&1
echo "=== ShimonVault user_data started at $(date) ==="

# ── 1. Install Docker ─────────────────────────────────────────────────────────
yum update -y
yum install -y docker openssl
systemctl enable docker
systemctl start docker

# Get private IP from network interface — always available, no metadata service needed
PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "=== Private IP: $PRIVATE_IP ==="

# ── 2. Install Tailscale ──────────────────────────────────────────────────────
yum install -y yum-utils
yum-config-manager --add-repo https://pkgs.tailscale.com/stable/amazon-linux/2/tailscale.repo
yum install -y tailscale
systemctl enable tailscaled
systemctl start tailscaled

# Join the Tailscale network
tailscale up --authkey="${tailscale_auth_key}" --hostname="${project_name}-app-blue" --accept-routes=false
echo "=== Tailscale joined ==="

# Wait for Tailscale IP to be assigned (up to 30s)
TAILSCALE_IP=""
for i in $(seq 1 15); do
  TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
  if [ -n "$TAILSCALE_IP" ]; then
    echo "=== Tailscale IP: $TAILSCALE_IP ==="
    break
  fi
  echo "Waiting for Tailscale IP... ($i/15)"
  sleep 2
done

if [ -z "$TAILSCALE_IP" ]; then
  echo "WARNING: Could not get Tailscale IP — using private IP for TLS SAN"
  TAILSCALE_IP="$PRIVATE_IP"
fi

# ── 3. Generate TLS certificates for Docker TCP socket ───────────────────────
TLS_DIR="/etc/docker/tls"
mkdir -p "$TLS_DIR"

# Certificate Authority
openssl genrsa -out "$TLS_DIR/ca-key.pem" 4096
openssl req -new -x509 -days 3650 -key "$TLS_DIR/ca-key.pem" \
  -out "$TLS_DIR/ca.pem" \
  -subj "/CN=shimonvault-docker-ca"

# Server certificate (valid for Tailscale IP + private IP + localhost)
openssl genrsa -out "$TLS_DIR/server-key.pem" 4096
openssl req -new -key "$TLS_DIR/server-key.pem" \
  -out "$TLS_DIR/server.csr" \
  -subj "/CN=shimonvault-docker-server"

cat > "$TLS_DIR/server-extfile.cnf" << EXTEOF
subjectAltName = IP:$${TAILSCALE_IP},IP:$${PRIVATE_IP},IP:127.0.0.1
extendedKeyUsage = serverAuth
EXTEOF

openssl x509 -req -days 3650 \
  -in "$TLS_DIR/server.csr" \
  -CA "$TLS_DIR/ca.pem" \
  -CAkey "$TLS_DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$TLS_DIR/server-cert.pem" \
  -extfile "$TLS_DIR/server-extfile.cnf"

# Client certificate (used by Portainer on proj-mgmt)
openssl genrsa -out "$TLS_DIR/client-key.pem" 4096
openssl req -new -key "$TLS_DIR/client-key.pem" \
  -out "$TLS_DIR/client.csr" \
  -subj "/CN=shimonvault-docker-client"

cat > "$TLS_DIR/client-extfile.cnf" << EXTEOF
extendedKeyUsage = clientAuth
EXTEOF

openssl x509 -req -days 3650 \
  -in "$TLS_DIR/client.csr" \
  -CA "$TLS_DIR/ca.pem" \
  -CAkey "$TLS_DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$TLS_DIR/client-cert.pem" \
  -extfile "$TLS_DIR/client-extfile.cnf"

# Lock down permissions
chmod 0400 "$TLS_DIR"/*-key.pem
chmod 0444 "$TLS_DIR"/ca.pem "$TLS_DIR"/server-cert.pem "$TLS_DIR"/client-cert.pem
echo "=== TLS certificates generated ==="

# ── 4. Configure Docker to listen on TCP 2376 with TLS ───────────────────────
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << DAEMONJSON
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2376"],
  "tls": true,
  "tlsverify": true,
  "tlscacert": "/etc/docker/tls/ca.pem",
  "tlscert": "/etc/docker/tls/server-cert.pem",
  "tlskey": "/etc/docker/tls/server-key.pem"
}
DAEMONJSON

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/override.conf << OVERRIDE
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
OVERRIDE

systemctl daemon-reload
systemctl restart docker
echo "=== Docker TCP 2376 with TLS enabled ==="

# ── 5. Store client certs in a retrievable location ──────────────────────────
mkdir -p /opt/shimonvault/docker-certs
cp "$TLS_DIR/ca.pem"          /opt/shimonvault/docker-certs/
cp "$TLS_DIR/client-cert.pem" /opt/shimonvault/docker-certs/
cp "$TLS_DIR/client-key.pem"  /opt/shimonvault/docker-certs/
chmod 644 /opt/shimonvault/docker-certs/*
echo "=== Client certs ready at /opt/shimonvault/docker-certs/ ==="

# ── 6. Write application .env ─────────────────────────────────────────────────
mkdir -p /opt/shimonvault

cat > /opt/shimonvault/.env << 'ENVEOF'
PROJECT_NAME=${project_name}
APP_VERSION=${app_version}
ENVIRONMENT=production

WRITE_DB_URL=postgresql+psycopg2://${db_user}:${db_password}@${rds_endpoint}:${rds_port}/${db_name}
READ_DB_URL=postgresql+psycopg2://${db_user}:${db_password}@${read_db_host}:5433/${db_name}

JWT_SECRET_KEY=${jwt_secret_key}
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60

AWS_REGION=${aws_region}
AWS_ACCOUNT_ID=${aws_account_id}

S3_BUCKET_DOCS=${s3_bucket_docs}
S3_BUCKET_REPORTS=${s3_bucket_reports}
S3_PRESIGNED_URL_EXPIRY=900

DYNAMODB_AUDIT_TABLE=${dynamodb_audit_table}
DYNAMODB_INCIDENTS_TABLE=${dynamodb_incidents_table}
DYNAMODB_MEETINGS_TABLE=${dynamodb_meetings_table}

SNS_TOPIC_SECURITY_ALERT=${sns_topic_security_alert}
SNS_TOPIC_CREDENTIAL_STUFFING=${sns_topic_credential_stuffing}
SNS_TOPIC_INFRA_ALERT=${sns_topic_infra_alert}
SNS_TOPIC_MEETING_REMINDERS=${sns_topic_meeting_reminders}

LAMBDA_BLOCK_IP_NAME=${lambda_block_ip_name}

SLACK_WEBHOOK_URL=${slack_webhook_url}
TELEGRAM_BOT_TOKEN=${telegram_bot_token}
TELEGRAM_CHAT_ID=${telegram_chat_id}

APP_SECURITY_GROUP_ID=${app_security_group_id}
ENVEOF

chmod 600 /opt/shimonvault/.env
echo "=== .env written ==="

# ── 7. Initialise Docker Swarm ────────────────────────────────────────────────
echo "=== Initialising Docker Swarm ==="
docker swarm init --advertise-addr "$PRIVATE_IP"
echo "=== Swarm initialised ==="

# ── 8. (OPTIONAL) Mount NFS share from proj-ubuntu01 ─────────────────────────
# proj-ubuntu01 (100.87.141.40) is the NFS server on the Tailscale mesh.
# This is OPTIONAL shared storage. The app does NOT need it to run.
# CHANGED: a failed mount no longer aborts the script. Previously 'set -e'
# meant a timed-out mount killed the whole startup and the app never deployed.
echo "=== Attempting optional NFS mount from proj-ubuntu01 ==="
yum install -y nfs-utils
sleep 5
mkdir -p /mnt/shimonvault-nfs

if mount -t nfs -o vers=4,soft,timeo=10,retrans=2 \
     100.87.141.40:/srv/nfs/shimonvault /mnt/shimonvault-nfs 2>/dev/null; then
  echo "=== NFS mounted at /mnt/shimonvault-nfs ==="
  # 'nofail' so a reboot never hangs waiting for NFS
  echo "100.87.141.40:/srv/nfs/shimonvault /mnt/shimonvault-nfs nfs vers=4,soft,timeo=10,retrans=2,nofail 0 0" >> /etc/fstab
else
  echo "=== WARNING: NFS unreachable — continuing without shared storage ==="
fi

# ── Relay so on-prem can reach RDS over Tailscale (for DB replication) ────────
echo "=== Starting RDS relay (socat) ==="
yum install -y socat
cat > /etc/systemd/system/rds-relay.service << RELAYEOF
[Unit]
Description=TCP relay to RDS for on-prem replication
After=network-online.target tailscaled.service
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:5432,fork,reuseaddr TCP:${rds_endpoint}:5432
Restart=always
[Install]
WantedBy=multi-user.target
RELAYEOF
systemctl daemon-reload
systemctl enable --now rds-relay
echo "=== RDS relay listening on :5432 → ${rds_endpoint}:5432 ==="

# ── 9. Create Portainer volume ────────────────────────────────────────────────
docker volume create portainer_data

# ── 10. Write Docker Stack compose file ──────────────────────────────────────
# CHANGED: removed the external NFS volume (shimonvault_app_data). The app is
# stateless — it stores data in S3 / DynamoDB / RDS — so it needs no local or
# shared volume. This also means the stack no longer fails when NFS is down.
source /opt/shimonvault/.env

cat > /opt/shimonvault/stack.yml << STACKEOF
version: "3.8"

services:

  app:
    image: mindmug/shimonvault-app:${container_tag}
    ports:
      - "8000:8000"
    environment:
      PROJECT_NAME: "$${PROJECT_NAME}"
      APP_VERSION: "$${APP_VERSION}"
      ENVIRONMENT: "$${ENVIRONMENT}"
      WRITE_DB_URL: "$${WRITE_DB_URL}"
      READ_DB_URL: "$${READ_DB_URL}"
      JWT_SECRET_KEY: "$${JWT_SECRET_KEY}"
      JWT_ALGORITHM: "$${JWT_ALGORITHM}"
      ACCESS_TOKEN_EXPIRE_MINUTES: "$${ACCESS_TOKEN_EXPIRE_MINUTES}"
      AWS_REGION: "$${AWS_REGION}"
      AWS_ACCOUNT_ID: "$${AWS_ACCOUNT_ID}"
      S3_BUCKET_DOCS: "$${S3_BUCKET_DOCS}"
      S3_BUCKET_REPORTS: "$${S3_BUCKET_REPORTS}"
      S3_PRESIGNED_URL_EXPIRY: "$${S3_PRESIGNED_URL_EXPIRY}"
      DYNAMODB_AUDIT_TABLE: "$${DYNAMODB_AUDIT_TABLE}"
      DYNAMODB_INCIDENTS_TABLE: "$${DYNAMODB_INCIDENTS_TABLE}"
      DYNAMODB_MEETINGS_TABLE: "$${DYNAMODB_MEETINGS_TABLE}"
      SNS_TOPIC_SECURITY_ALERT: "$${SNS_TOPIC_SECURITY_ALERT}"
      SNS_TOPIC_CREDENTIAL_STUFFING: "$${SNS_TOPIC_CREDENTIAL_STUFFING}"
      SNS_TOPIC_INFRA_ALERT: "$${SNS_TOPIC_INFRA_ALERT}"
      SNS_TOPIC_MEETING_REMINDERS: "$${SNS_TOPIC_MEETING_REMINDERS}"
      LAMBDA_BLOCK_IP_NAME: "$${LAMBDA_BLOCK_IP_NAME}"
      SLACK_WEBHOOK_URL: "$${SLACK_WEBHOOK_URL}"
      TELEGRAM_BOT_TOKEN: "$${TELEGRAM_BOT_TOKEN}"
      TELEGRAM_CHAT_ID: "$${TELEGRAM_CHAT_ID}"
      APP_SECURITY_GROUP_ID: "$${APP_SECURITY_GROUP_ID}"
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
        delay: 10s
        max_attempts: 5
      update_config:
        parallelism: 1
        delay: 10s
        failure_action: rollback
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

STACKEOF

echo "=== stack.yml written ==="

# ── 11. Pull image and deploy stack ──────────────────────────────────────────
echo "=== Pulling app image ==="
docker pull "mindmug/shimonvault-app:${container_tag}"

echo "=== Deploying stack: shimonvault ==="
docker stack deploy \
  --compose-file /opt/shimonvault/stack.yml \
  --with-registry-auth \
  shimonvault

echo "=== Stack deployed ==="
docker node ls
docker stack services shimonvault

# ── 12. Poll /health ─────────────────────────────────────────────────────────
echo "=== Polling /health ==="
for i in $(seq 1 30); do
  sleep 10
  STATUS=$(curl -s -o /dev/null -w "%%{http_code}" http://localhost:8000/health 2>/dev/null || echo "000")
  echo "[poll $i/30] HTTP $STATUS"
  if [ "$STATUS" = "200" ]; then
    echo "=== App is healthy (poll $i) ==="
    break
  fi
done

echo "=== Tailscale IP for Portainer: $TAILSCALE_IP ==="
echo "=== user_data finished at $(date) ==="
