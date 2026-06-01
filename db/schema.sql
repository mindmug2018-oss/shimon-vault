-- ─────────────────────────────────────────────────────────────
-- ShimonVault — Database Schema
-- Run on both AWS RDS (primary) and on-prem PostgreSQL (replica)
-- ─────────────────────────────────────────────────────────────

-- Users table
CREATE TABLE IF NOT EXISTS users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       VARCHAR(255) UNIQUE NOT NULL,
    username    VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role        VARCHAR(20) NOT NULL DEFAULT 'viewer'
                CHECK (role IN ('admin', 'editor', 'viewer')),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Documents table
CREATE TABLE IF NOT EXISTS documents (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title       VARCHAR(500) NOT NULL,
    s3_key      VARCHAR(1000) NOT NULL,  -- S3 object key (path in bucket)
    s3_bucket   VARCHAR(255) NOT NULL,
    file_size   BIGINT,
    mime_type   VARCHAR(100),
    version     INTEGER NOT NULL DEFAULT 1,
    is_deleted  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Meetings table
CREATE TABLE IF NOT EXISTS meetings (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organizer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title       VARCHAR(500) NOT NULL,
    description TEXT,
    join_token  VARCHAR(255) UNIQUE NOT NULL,
    starts_at   TIMESTAMPTZ NOT NULL,
    ends_at     TIMESTAMPTZ NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'scheduled'
                CHECK (status IN ('scheduled', 'active', 'expired', 'cancelled')),
    eventbridge_rule_name VARCHAR(255),  -- tracks the AWS EventBridge rule for this meeting
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Meeting participants
CREATE TABLE IF NOT EXISTS participants (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id  UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at   TIMESTAMPTZ,    -- NULL if invited but not yet joined
    UNIQUE(meeting_id, user_id)
);

-- Audit events — every action in the platform is logged here
CREATE TABLE IF NOT EXISTS audit_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID REFERENCES users(id),  -- NULL for anonymous/failed auth
    event_type  VARCHAR(100) NOT NULL,
    resource_type VARCHAR(50),   -- 'document', 'meeting', 'auth', etc.
    resource_id VARCHAR(255),    -- the ID of the affected resource
    ip_address  INET,
    user_agent  TEXT,
    request_path VARCHAR(500),
    response_status INTEGER,
    severity    VARCHAR(20) NOT NULL DEFAULT 'info'
                CHECK (severity IN ('info', 'warning', 'critical')),
    details     JSONB,           -- any extra structured data
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────
-- Indexes for common query patterns
-- ─────────────────────────────────────────────

-- Quick lookup of user by email (used in login)
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);

-- List documents for a user
CREATE INDEX IF NOT EXISTS idx_documents_owner ON documents(owner_id) WHERE is_deleted = FALSE;

-- List upcoming meetings
CREATE INDEX IF NOT EXISTS idx_meetings_status ON meetings(status, starts_at);

-- Audit feed queries (sort by newest, filter by user)
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_events(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_severity ON audit_events(severity, created_at DESC);

-- ─────────────────────────────────────────────
-- auto-update updated_at columns
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER documents_updated_at
    BEFORE UPDATE ON documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
