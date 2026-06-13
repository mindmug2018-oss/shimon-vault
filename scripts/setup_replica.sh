#!/bin/bash
# scripts/setup_replica.sh
# Run on proj-mgmt AFTER terraform apply to configure PostgreSQL logical
# replication: RDS (primary, AWS) -> proj-ubuntu01 (replica, on-prem).
#
# CHANGED for the relay design: RDS lives in a private AWS subnet and is not
# reachable from on-prem directly. The app EC2 runs a socat relay on :5432 that
# forwards to RDS, and it's on the Tailscale mesh. So both proj-mgmt (setup) and
# proj-ubuntu01 (the live subscription) reach RDS through the EC2's Tailscale IP.
#
# Requires: socat relay in the EC2 user_data + the 5432 Tailscale SG rule.
#
# Usage: bash scripts/setup_replica.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"
KEY="$HOME/.ssh/id_ed25519_shimonvault"

RDS_ENDPOINT=$(cd "$TF_DIR" && terraform output -raw rds_endpoint)
DB_NAME="${DB_NAME:-shimonvault}"
DB_USER="${DB_USER:-shimonvault}"
DB_PASSWORD="${DB_PASSWORD:-$(grep DB_PASSWORD "$SCRIPT_DIR/../app/.env" | cut -d= -f2)}"
REPLICA_HOST="100.87.141.40"   # proj-ubuntu01 Tailscale IP — stable
REPLICA_PORT=5433

# ── Find the RDS relay (app EC2 Tailscale IP) ────────────────────────────────
# Everyone reaches RDS through this: <EC2 Tailscale IP>:5432 -> socat -> RDS:5432
echo "0️⃣  Finding the RDS relay (app EC2 Tailscale IP)..."
BASTION_IP=$(cd "$TF_DIR" && terraform output -raw bastion_public_ip)
APP_EC2_IP=$(aws ec2 describe-instances --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=shimonvault-app-blue" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
RDS_RELAY=$(ssh -i "$KEY" -o StrictHostKeyChecking=no \
  -o ProxyJump=ec2-user@"$BASTION_IP" ec2-user@"$APP_EC2_IP" "tailscale ip -4" 2>/dev/null | head -1)

if [ -z "$RDS_RELAY" ]; then
  echo "   ❌ Could not get the EC2 Tailscale IP. Is the instance up and on Tailscale?"
  exit 1
fi
RDS_RELAY_PORT=5432

echo ""
echo "🗄️  ShimonVault — Configuring PostgreSQL Logical Replication"
echo "   Primary (RDS, via relay): $RDS_RELAY:$RDS_RELAY_PORT  ->  $RDS_ENDPOINT"
echo "   Replica (proj-ubuntu01):  $REPLICA_HOST:$REPLICA_PORT"
echo ""

# ── Step 1: Create replication user + publication on RDS (via relay) ─────────
echo "1️⃣  Creating replication user and publication on RDS..."
docker run --rm --network host \
    -e PGPASSWORD="$DB_PASSWORD" \
    postgres:16-alpine \
    psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" << SQLEOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '$DB_PASSWORD';
    END IF;
END
\$\$;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;

DROP PUBLICATION IF EXISTS shimonvault_pub;
CREATE PUBLICATION shimonvault_pub FOR ALL TABLES;

SELECT 'Publication created: ' || pubname FROM pg_publication WHERE pubname = 'shimonvault_pub';
SQLEOF
echo "   ✅ Replication user and publication created on RDS"
echo ""

# ── Step 2: Start PostgreSQL 16 replica on proj-ubuntu01 ─────────────────────
echo "2️⃣  Starting PostgreSQL 16 replica on proj-ubuntu01..."
ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" << SSHEOF
set -e
docker stop shimonvault-postgres-replica 2>/dev/null || true
docker rm shimonvault-postgres-replica 2>/dev/null || true

mkdir -p /opt/shimonvault/postgres-replica/data
mkdir -p /opt/shimonvault/postgres-replica/conf

cat > /opt/shimonvault/postgres-replica/conf/postgresql.conf << 'PGCONF'
listen_addresses = '*'
port = 5433
max_connections = 100
wal_level = replica
hot_standby = on
PGCONF

cat > /opt/shimonvault/postgres-replica/conf/pg_hba.conf << 'PGCONF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             100.64.0.0/10           md5
host    replication     replicator      100.64.0.0/10           md5
PGCONF

docker run -d \
    --name shimonvault-postgres-replica \
    --restart unless-stopped \
    -p 5433:5433 \
    -e POSTGRES_DB=$DB_NAME \
    -e POSTGRES_USER=$DB_USER \
    -e POSTGRES_PASSWORD=$DB_PASSWORD \
    -v /opt/shimonvault/postgres-replica/data:/var/lib/postgresql/data \
    -v /opt/shimonvault/postgres-replica/conf/postgresql.conf:/etc/postgresql/postgresql.conf \
    -v /opt/shimonvault/postgres-replica/conf/pg_hba.conf:/etc/postgresql/pg_hba.conf \
    postgres:16-alpine \
    postgres -c config_file=/etc/postgresql/postgresql.conf \
             -c hba_file=/etc/postgresql/pg_hba.conf

echo "Waiting for PostgreSQL to start..."
sleep 10
docker exec shimonvault-postgres-replica pg_isready -U $DB_USER -d $DB_NAME -p 5433
echo "✅ PostgreSQL 16 replica container started on port 5433"
SSHEOF
echo "   ✅ Replica container running on proj-ubuntu01:5433"
echo ""

# ── Step 3: Create subscription on replica (connects to RDS via the relay) ───
echo "3️⃣  Creating logical replication subscription on replica..."
sleep 5

ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" << SSHEOF
docker exec -i shimonvault-postgres-replica \
    psql -U $DB_USER -d $DB_NAME -p 5433 << SQLEOF
DROP SUBSCRIPTION IF EXISTS shimonvault_sub;
CREATE SUBSCRIPTION shimonvault_sub
    CONNECTION 'host=$RDS_RELAY port=$RDS_RELAY_PORT dbname=$DB_NAME user=replicator password=$DB_PASSWORD sslmode=require'
    PUBLICATION shimonvault_pub
    WITH (copy_data = true);

SELECT 'Subscription created: ' || subname FROM pg_subscription WHERE subname = 'shimonvault_sub';
SQLEOF
echo "✅ Subscription created — replica will now sync from RDS"
SSHEOF
echo "   ✅ Logical replication subscription active"
echo ""

# ── Step 4: Verify ───────────────────────────────────────────────────────────
echo "4️⃣  Verifying replication status..."
sleep 5

echo "   RDS primary — replication slots:"
docker run --rm --network host \
    -e PGPASSWORD="$DB_PASSWORD" \
    postgres:16-alpine \
    psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "SELECT slot_name, active, confirmed_flush_lsn FROM pg_replication_slots;" \
    2>/dev/null || echo "   (could not connect to verify)"

echo ""
echo "   Replica — subscription status:"
ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" \
    "docker exec shimonvault-postgres-replica \
     psql -U $DB_USER -d $DB_NAME -p 5433 \
     -c 'SELECT subname, subenabled, subslotname FROM pg_subscription;'" \
    2>/dev/null || echo "   (could not connect to verify)"

echo ""
echo "════════════════════════════════════════════════════════"
echo "✅ Replication setup complete!"
echo "   Writes → RDS primary | Reads → proj-ubuntu01 replica"
echo "   Verify live: POST a doc via the API, then query the replica:"
echo "     ssh user1@100.87.141.40 \"docker exec shimonvault-postgres-replica \\"
echo "       psql -U $DB_USER -d $DB_NAME -p 5433 -c 'SELECT * FROM documents LIMIT 5;'\""
echo "════════════════════════════════════════════════════════"
