#!/bin/bash
# scripts/setup_replica.sh
# Run on proj-mgmt AFTER terraform apply to configure the PostgreSQL
# logical replication replica on proj-ubuntu01.
#
# Architecture:
#   RDS PostgreSQL 16 (primary, AWS)  →  proj-ubuntu01 PostgreSQL 16 (replica, on-prem)
#   App EC2 writes to RDS             →  App EC2 reads from proj-ubuntu01 via Tailscale
#
# This demonstrates:
#   - Database replication (logical replication via publication/subscription)
#   - Read/write splitting (app uses two DB URLs)
#   - High availability (reads continue if RDS is slow)
#   - Hybrid cloud (AWS primary → on-prem replica via Tailscale)
#
# Usage: bash scripts/setup_replica.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

# Read values from terraform outputs and env
RDS_ENDPOINT=$(cd "$TF_DIR" && terraform output -raw rds_endpoint)
RDS_PORT=5432
DB_NAME="${DB_NAME:-shimonvault}"
DB_USER="${DB_USER:-shimonvault}"
DB_PASSWORD="${DB_PASSWORD:-$(grep DB_PASSWORD "$SCRIPT_DIR/../app/.env" | cut -d= -f2)}"
REPLICA_HOST="100.87.141.40"   # proj-ubuntu01 Tailscale IP — stable, never changes
REPLICA_PORT=5433               # use 5433 to avoid conflict with proj-mgmt port 5432

echo "🗄️  ShimonVault — Configuring PostgreSQL Logical Replication"
echo ""
echo "   Primary (RDS):   $RDS_ENDPOINT:$RDS_PORT"
echo "   Replica (ubuntu): $REPLICA_HOST:$REPLICA_PORT"
echo ""

# ── Step 1: Create replication user on RDS ────────────────────────────────────
echo "1️⃣  Creating replication user on RDS primary..."

# Run SQL via Docker (psql may not be installed on proj-mgmt)
docker run --rm \
    -e PGPASSWORD="$DB_PASSWORD" \
    postgres:16-alpine \
    psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$DB_USER" -d "$DB_NAME" << SQLEOF
-- Create dedicated replication user
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '$DB_PASSWORD';
    END IF;
END
\$\$;

-- Grant replicator access to all tables for logical replication
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;

-- Create publication for all tables
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

# Stop and remove old PostgreSQL 15 container if running
docker stop shimonvault-postgres-replica 2>/dev/null || true
docker rm shimonvault-postgres-replica 2>/dev/null || true

# Create data directory
mkdir -p /opt/shimonvault/postgres-replica/data
mkdir -p /opt/shimonvault/postgres-replica/conf

# Write postgresql.conf for replica
cat > /opt/shimonvault/postgres-replica/conf/postgresql.conf << 'PGCONF'
listen_addresses = '*'
port = 5433
max_connections = 100
wal_level = replica
hot_standby = on
PGCONF

# Write pg_hba.conf — allow connections from Tailscale CGNAT range
cat > /opt/shimonvault/postgres-replica/conf/pg_hba.conf << 'PGCONF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             100.64.0.0/10           md5
host    replication     replicator      100.64.0.0/10           md5
PGCONF

# Start PostgreSQL 16 container (must match RDS version)
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

# Check it's running
docker exec shimonvault-postgres-replica pg_isready -U $DB_USER -d $DB_NAME -p 5433
echo "✅ PostgreSQL 16 replica container started on port 5433"
SSHEOF
echo "   ✅ Replica container running on proj-ubuntu01:5433"
echo ""

# ── Step 3: Create subscription on replica ────────────────────────────────────
echo "3️⃣  Creating logical replication subscription on replica..."
sleep 5  # wait for replica to fully start

ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" << SSHEOF
# Create schema and tables on replica first (must exist before subscription)
PGPASSWORD=$DB_PASSWORD docker exec -i shimonvault-postgres-replica \
    psql -U $DB_USER -d $DB_NAME -p 5433 << SQLEOF
-- Create subscription to RDS primary
-- This pulls all existing data AND subscribes to ongoing changes
DROP SUBSCRIPTION IF EXISTS shimonvault_sub;
CREATE SUBSCRIPTION shimonvault_sub
    CONNECTION 'host=$RDS_ENDPOINT port=$RDS_PORT dbname=$DB_NAME user=replicator password=$DB_PASSWORD sslmode=require'
    PUBLICATION shimonvault_pub
    WITH (copy_data = true);

SELECT 'Subscription created: ' || subname FROM pg_subscription WHERE subname = 'shimonvault_sub';
SQLEOF
echo "✅ Subscription created — replica will now sync from RDS"
SSHEOF
echo "   ✅ Logical replication subscription active"
echo ""

# ── Step 4: Verify replication is working ─────────────────────────────────────
echo "4️⃣  Verifying replication status..."
sleep 5

echo "   RDS primary — replication slots:"
docker run --rm \
    -e PGPASSWORD="$DB_PASSWORD" \
    postgres:16-alpine \
    psql -h "$RDS_ENDPOINT" -p "$RDS_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -c "SELECT slot_name, active, confirmed_flush_lsn FROM pg_replication_slots;" \
    2>/dev/null || echo "   (could not connect to verify)"

echo ""
echo "   Replica — subscription status:"
ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" \
    "PGPASSWORD=$DB_PASSWORD docker exec shimonvault-postgres-replica \
     psql -U $DB_USER -d $DB_NAME -p 5433 \
     -c 'SELECT subname, subenabled, subslotname FROM pg_subscription;'" \
    2>/dev/null || echo "   (could not connect to verify)"

echo ""
echo "════════════════════════════════════════════════════════"
echo "✅ Replication setup complete!"
echo ""
echo "   Write URL (RDS primary):    postgresql+psycopg2://$DB_USER:***@$RDS_ENDPOINT:$RDS_PORT/$DB_NAME"
echo "   Read URL  (on-prem replica): postgresql+psycopg2://$DB_USER:***@$REPLICA_HOST:$REPLICA_PORT/$DB_NAME"
echo ""
echo "   The app already uses both URLs via WRITE_DB_URL and READ_DB_URL."
echo "   All INSERT/UPDATE/DELETE → RDS"
echo "   All SELECT (list, download, audit feed) → proj-ubuntu01"
echo ""
echo "   To verify replication live:"
echo "   1. Create a document via the API (POST /docs/upload)"
echo "   2. Query the replica directly:"
echo "      ssh user1@100.87.141.40"
echo "      PGPASSWORD=\$DB_PASSWORD docker exec shimonvault-postgres-replica \\"
echo "        psql -U $DB_USER -d $DB_NAME -p 5433 -c 'SELECT * FROM documents LIMIT 5;'"
echo "════════════════════════════════════════════════════════"
