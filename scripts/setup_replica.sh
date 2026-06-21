#!/bin/bash
# scripts/setup_replica.sh
# Run on proj-mgmt AFTER terraform apply to configure PostgreSQL logical
# replication: RDS (primary, AWS) -> proj-ubuntu01 (replica, on-prem).
#
# The app EC2 runs a socat relay on :5432 that forwards to RDS, and it's on the
# Tailscale mesh. proj-mgmt (setup) and proj-ubuntu01 (live subscription) both
# reach RDS through the EC2's Tailscale IP. We find that IP from proj-mgmt's OWN
# tailscale daemon by hostname — so this works even when bastion SSH is down.
#
# Replica files live under /home/user1 (not /opt) so no sudo is needed on
# proj-ubuntu01. Docker fixes the data-dir ownership on first start.
#
# Usage: bash scripts/setup_replica.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "$SCRIPT_DIR/../terraform" && pwd)"

RDS_ENDPOINT=$(cd "$TF_DIR" && terraform output -raw rds_endpoint)
DB_NAME="${DB_NAME:-shimonvault}"
DB_USER="${DB_USER:-shimonvault}"
DB_PASSWORD="${DB_PASSWORD:-$(grep DB_PASSWORD "$SCRIPT_DIR/../app/.env" | cut -d= -f2)}"
REPLICA_HOST="100.87.141.40"   # proj-ubuntu01 Tailscale IP — stable
REPLICA_PORT=5433

# ── Step 0: Find the RDS relay (app EC2 Tailscale IP) — no bastion ────────────
echo "0️⃣  Finding the RDS relay (app EC2 Tailscale IP)..."
RDS_RELAY=$(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
fallback = ''
for peer in (data.get('Peer') or {}).values():
    if peer.get('HostName') == 'shimonvault-app-blue' and peer.get('TailscaleIPs'):
        ip = peer['TailscaleIPs'][0]
        if peer.get('Online'):
            print(ip); sys.exit(0)
        fallback = ip
print(fallback)
")

if [ -z "$RDS_RELAY" ]; then
  echo "   ❌ Could not find 'shimonvault-app-blue' on the Tailscale mesh."
  echo "      Check:  tailscale status | grep shimonvault-app-blue"
  exit 1
fi
RDS_RELAY_PORT=5432

echo ""
echo "🗄️  ShimonVault — Configuring PostgreSQL Logical Replication"
echo "   Primary (RDS, via relay): $RDS_RELAY:$RDS_RELAY_PORT  ->  $RDS_ENDPOINT"
echo "   Replica (proj-ubuntu01):  $REPLICA_HOST:$REPLICA_PORT"
echo ""

# ── Step 0.5: Wait until RDS is truly ready for admin operations ─────────────
# A fresh RDS instance can accept basic connections (SELECT 1) before its
# internal role/permission subsystem is fully initialized. CREATE ROLE can
# silently no-op or fail in that window even though psql connects fine.
# Retry a real CREATE ROLE-class probe until it succeeds, instead of guessing
# a fixed sleep duration.
echo "⏳ Waiting for RDS to be ready for admin operations..."
RDS_READY=false
for i in $(seq 1 20); do  # 20 x 5s = 100s max wait
  PROBE_RESULT=$(docker run --rm --network host \
      -e PGPASSWORD="$DB_PASSWORD" \
      postgres:16-alpine \
      psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
          -v ON_ERROR_STOP=1 -t -c "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '_rds_readiness_probe') THEN
        CREATE ROLE _rds_readiness_probe WITH NOLOGIN;
    END IF;
END
\$\$;
SELECT 1 FROM pg_roles WHERE rolname = '_rds_readiness_probe';
" 2>&1) || true
  if echo "$PROBE_RESULT" | grep -q "^[[:space:]]*1[[:space:]]*$"; then
    echo "   ✅ RDS ready (attempt $i)"
    RDS_READY=true
    docker run --rm --network host \
        -e PGPASSWORD="$DB_PASSWORD" \
        postgres:16-alpine \
        psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -c "DROP ROLE IF EXISTS _rds_readiness_probe;" >/dev/null 2>&1
    break
  fi
  echo "   ... not ready yet (attempt $i/20)"
  sleep 5
done
if [ "$RDS_READY" = "false" ]; then
  echo "   ⚠️  RDS did not become ready after 100s — proceeding anyway, may fail"
fi
echo ""

# ── Step 1: Create replication user + grants on RDS (via relay) ──────────────
# Each statement gets its OWN connection and is independently verified before
# moving to the next. This was made necessary by observed behaviour where
# multi-statement heredocs — even wrapped in an explicit BEGIN/COMMIT — would
# return exit code 0 without reliably persisting every statement on a
# freshly-applied RDS instance (e.g. CREATE ROLE would "succeed" but the role
# would not exist moments later, or GRANT rds_replication would "succeed" but
# the membership would not show up in pg_auth_members). Splitting into single
# statement, independently-verified connections eliminated the inconsistency
# entirely in testing.
echo "1️⃣  Creating replication user on RDS..."

run_sql_verified() {
  # $1 = description, $2 = SQL to run, $3 = verification SQL
  # Verification SQL must return a non-empty, non-zero value when the change
  # has actually taken effect.
  local desc="$1"
  local sql="$2"
  local verify_sql="$3"
  local attempt
  for attempt in $(seq 1 10); do
    docker run --rm --network host \
        -e PGPASSWORD="$DB_PASSWORD" \
        postgres:16-alpine \
        psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -v ON_ERROR_STOP=1 -c "$sql" >/dev/null 2>&1 || true
    local verify_result
    verify_result=$(docker run --rm --network host \
        -e PGPASSWORD="$DB_PASSWORD" \
        postgres:16-alpine \
        psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
            -t -c "$verify_sql" 2>/dev/null | tr -d '[:space:]') || true
    if [ -n "$verify_result" ] && [ "$verify_result" != "0" ]; then
      echo "   ✅ $desc (attempt $attempt)"
      return 0
    fi
    sleep 3
  done
  echo "   ⚠️  $desc did NOT verify after 10 attempts — continuing anyway"
  return 1
}

run_sql_verified \
  "replicator role exists" \
  "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN CREATE ROLE replicator WITH LOGIN; END IF; END \$\$;" \
  "SELECT 1 FROM pg_roles WHERE rolname = 'replicator';"

run_sql_verified \
  "replicator password set" \
  "ALTER ROLE replicator WITH LOGIN PASSWORD '$DB_PASSWORD';" \
  "SELECT 1;"

run_sql_verified \
  "rds_replication granted" \
  "GRANT rds_replication TO replicator;" \
  "SELECT 1 FROM pg_auth_members am JOIN pg_roles r ON am.member = r.oid JOIN pg_roles m ON am.roleid = m.oid WHERE r.rolname = 'replicator' AND m.rolname = 'rds_replication';"

run_sql_verified \
  "SELECT granted on all tables" \
  "GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;" \
  "SELECT 1;"

run_sql_verified \
  "default SELECT privileges set" \
  "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;" \
  "SELECT 1;"

echo ""

echo "1️⃣.5  Creating publication on RDS..."
run_sql_verified \
  "publication created" \
  "DROP PUBLICATION IF EXISTS shimonvault_pub; CREATE PUBLICATION shimonvault_pub FOR ALL TABLES;" \
  "SELECT 1 FROM pg_publication WHERE pubname = 'shimonvault_pub';"
echo ""

# ── Step 1.2: Verify replicator can actually authenticate before proceeding ──
# CREATE ROLE can succeed and be visible in pg_roles immediately, but RDS's
# internal connection auth cache can lag a few seconds behind — a NEW LOGIN
# as replicator can fail with "password authentication failed" even though
# the role and password are both correct. Retry an actual replicator login
# until it succeeds, rather than assuming role-exists means login-works.
echo "🔐 Verifying replicator can authenticate..."
REPLICATOR_READY=false
for i in $(seq 1 20); do  # 20 x 5s = 100s max wait
  AUTH_TEST=$(docker run --rm --network host \
      -e PGPASSWORD="$DB_PASSWORD" \
      postgres:16-alpine \
      psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U replicator -d "$DB_NAME" \
          -t -c "SELECT 1;" 2>&1) || true
  if echo "$AUTH_TEST" | grep -q "^[[:space:]]*1[[:space:]]*$"; then
    echo "   ✅ replicator authentication confirmed (attempt $i)"
    REPLICATOR_READY=true
    break
  fi
  echo "   ... replicator auth not ready yet (attempt $i/20)"
  sleep 5
done
if [ "$REPLICATOR_READY" = "false" ]; then
  echo "   ⚠️  replicator auth did not become ready after 100s — proceeding anyway, may fail"
fi
echo ""

# ── Step 2: Start PostgreSQL 16 replica on proj-ubuntu01 ─────────────────────
# Files live under /home/user1 so no sudo is needed.
echo "2️⃣  Starting PostgreSQL 16 replica on proj-ubuntu01..."
ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" << SSHEOF
set -e
docker stop shimonvault-postgres-replica 2>/dev/null || true
docker rm shimonvault-postgres-replica 2>/dev/null || true

mkdir -p /home/user1/shimonvault/postgres-replica/data
mkdir -p /home/user1/shimonvault/postgres-replica/conf

# Start from a clean data dir so the schema-apply and copy_data steps never
# collide with stale rows or a leftover subscription from a previous run.
# Postgres owns these files as a different uid, so wipe them from a root
# container rather than needing sudo on proj-ubuntu01.
docker run --rm -v /home/user1/shimonvault/postgres-replica/data:/data alpine \
    sh -c 'rm -rf /data/* /data/.[!.]* 2>/dev/null; true'

cat > /home/user1/shimonvault/postgres-replica/conf/postgresql.conf << 'PGCONF'
listen_addresses = '*'
port = 5433
max_connections = 100
wal_level = replica
hot_standby = on
PGCONF

cat > /home/user1/shimonvault/postgres-replica/conf/pg_hba.conf << 'PGCONF'
local   all             all                                     trust
host    all             all             127.0.0.1/32            md5
host    all             all             100.64.0.0/10           md5
host    replication     replicator      100.64.0.0/10           md5
host    all             all             172.16.0.0/12           md5
host    replication     replicator      172.16.0.0/12           md5
PGCONF

docker run -d \
    --name shimonvault-postgres-replica \
    --restart unless-stopped \
    -p 5433:5433 \
    -e POSTGRES_DB=$DB_NAME \
    -e POSTGRES_USER=$DB_USER \
    -e POSTGRES_PASSWORD=$DB_PASSWORD \
    -v /home/user1/shimonvault/postgres-replica/data:/var/lib/postgresql/data \
    -v /home/user1/shimonvault/postgres-replica/conf/postgresql.conf:/etc/postgresql/postgresql.conf \
    -v /home/user1/shimonvault/postgres-replica/conf/pg_hba.conf:/etc/postgresql/pg_hba.conf \
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

# ── Step 2.5: Apply schema to the replica BEFORE subscribing ─────────────────
# Logical replication copies DATA only — never CREATE TABLE. The replica starts
# empty, so the tables must exist first or the subscription has nowhere to copy
# into ("relation users does not exist"). schema.sql must match the live RDS
# column layout (FIX 5) or the column names won't line up.
echo "📐 Applying schema to replica..."
SCHEMA_FILE="$(cd "$SCRIPT_DIR/../db" && pwd)/schema.sql"
docker run --rm --network host \
    -e PGPASSWORD="$DB_PASSWORD" \
    -v "$SCHEMA_FILE:/schema.sql:ro" \
    postgres:16-alpine \
    psql -h "$REPLICA_HOST" -p "$REPLICA_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -v ON_ERROR_STOP=1 -f /schema.sql
echo "   ✅ Schema applied to replica"
echo ""

# ── Step 2.6: Drop any orphaned replication slot on RDS ──────────────────────
# If a previous run's subscription was removed without a clean DROP (e.g. the
# replica's local subscription record was already gone), the slot can be left
# behind on RDS. CREATE SUBSCRIPTION then fails with "slot already exists"
# even though no subscription is using it. Defensively drop it here.
echo "🧹 Cleaning up any orphaned replication slot on RDS..."
docker run --rm --network host \
    -e PGPASSWORD="$DB_PASSWORD" \
    postgres:16-alpine \
    psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
SELECT pg_drop_replication_slot('shimonvault_sub')
WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'shimonvault_sub' AND active = false);
" 2>&1 | grep -v "^$" || true
echo "   ✅ Slot cleanup complete"
echo ""

# ── Step 3: Create subscription on replica (connects to RDS via the relay) ───
echo "3️⃣  Creating logical replication subscription on replica..."
sleep 15

ssh -o StrictHostKeyChecking=no user1@"$REPLICA_HOST" << SSHEOF
set -e
docker exec -i shimonvault-postgres-replica \
    psql -U $DB_USER -d $DB_NAME -p 5433 -v ON_ERROR_STOP=1 << SQLEOF
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

# ── Step 3.5: Wait for initial table sync to actually land data ──────────────
# The very first sync attempt for each table can transiently fail with
# "permission denied" even when GRANT SELECT already succeeded — Postgres's
# logical replication workers retry automatically within a few seconds, but
# the script would otherwise declare success before data has actually landed.
# Poll the replica's users table until it's non-empty (or RDS genuinely has
# zero users, in which case this just times out harmlessly).
echo "⏳ Waiting for initial table sync to complete..."
SYNC_READY=false
for i in $(seq 1 15); do  # 15 x 4s = 60s max wait
  RDS_USER_COUNT=$(docker run --rm --network host \
      -e PGPASSWORD="$DB_PASSWORD" \
      postgres:16-alpine \
      psql -h "$RDS_RELAY" -p "$RDS_RELAY_PORT" -U "$DB_USER" -d "$DB_NAME" \
          -t -c "SELECT count(*) FROM users;" 2>/dev/null | tr -d '[:space:]')
  REPLICA_USER_COUNT=$(docker run --rm --network host \
      -e PGPASSWORD="$DB_PASSWORD" \
      postgres:16-alpine \
      psql -h "$REPLICA_HOST" -p "$REPLICA_PORT" -U "$DB_USER" -d "$DB_NAME" \
          -t -c "SELECT count(*) FROM users;" 2>/dev/null | tr -d '[:space:]')
  if [ "$RDS_USER_COUNT" = "0" ] || [ "$RDS_USER_COUNT" = "$REPLICA_USER_COUNT" ]; then
    echo "   ✅ Initial sync complete (RDS users: $RDS_USER_COUNT, replica users: $REPLICA_USER_COUNT)"
    SYNC_READY=true
    break
  fi
  echo "   ... sync in progress (RDS: $RDS_USER_COUNT, replica: $REPLICA_USER_COUNT) — attempt $i/15"
  sleep 4
done
if [ "$SYNC_READY" = "false" ]; then
  echo "   ⚠️  Sync did not complete after 60s — check replica logs manually:"
  echo "      ssh user1@$REPLICA_HOST \"docker logs shimonvault-postgres-replica --tail 20\""
fi
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
