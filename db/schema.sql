-- ─────────────────────────────────────────────────────────────
-- ShimonVault — Database Schema (on-prem read replica)
--
-- This file mirrors app/models.py, which is the single source of truth.
-- RDS itself is built by SQLAlchemy's Base.metadata.create_all(); this script
-- recreates the SAME tables on the proj-ubuntu01 read replica so that logical
-- replication has matching tables to copy into.
--
-- Design choices that make this safe for a replication SUBSCRIBER:
--   * Enum columns (role, status, event_type) are VARCHAR, not native PG enum
--     types. Logical replication delivers values as text, and a VARCHAR target
--     accepts whatever the primary sends, so an enum-label mismatch can never
--     stall replication. SQLAlchemy still resolves the text back to the Python
--     enum on read, regardless of the underlying column type.
--   * Timestamps are TIMESTAMP (no time zone), matching SQLAlchemy's DateTime.
--   * No triggers: SQLAlchemy maintains updated_at in the application layer, so
--     RDS has none, and the replica must not add behavior the primary lacks.
--   * Foreign keys mirror the models. They do not block replication: the apply
--     worker runs with session_replication_role=replica, which skips FK checks.
-- ─────────────────────────────────────────────────────────────

-- ─── users ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       VARCHAR(255) UNIQUE NOT NULL,
    username    VARCHAR(100) UNIQUE NOT NULL,
    hashed_pw   VARCHAR(255) NOT NULL,
    role        VARCHAR(20)  NOT NULL,            -- UserRole: ADMIN / EDITOR / VIEWER
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    suspended   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMP             DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_users_email ON users(email);

-- ─── documents ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS documents (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename     VARCHAR(255) NOT NULL,
    s3_key       VARCHAR(512) NOT NULL,
    content_type VARCHAR(100) NOT NULL,
    size_bytes   INTEGER      NOT NULL,
    version      INTEGER      NOT NULL DEFAULT 1,
    parent_id    UUID         REFERENCES documents(id),
    owner_id     UUID         NOT NULL REFERENCES users(id),
    status       VARCHAR(20)  NOT NULL,           -- DocumentStatus: ACTIVE / DELETED
    description  TEXT,
    created_at   TIMESTAMP    NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMP
);

-- ─── meetings ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meetings (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title                 VARCHAR(255) NOT NULL,
    description           TEXT,
    organizer_id          UUID NOT NULL REFERENCES users(id),
    join_token            VARCHAR(64) UNIQUE NOT NULL,
    status                VARCHAR(20) NOT NULL,    -- MeetingStatus: SCHEDULED / ACTIVE / EXPIRED / CANCELLED
    scheduled_at          TIMESTAMP NOT NULL,
    ends_at               TIMESTAMP NOT NULL,
    eventbridge_rule_name VARCHAR(255),
    created_at            TIMESTAMP NOT NULL DEFAULT now(),
    archived_at           TIMESTAMP
);

-- ─── participants ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS participants (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    meeting_id  UUID NOT NULL REFERENCES meetings(id),
    user_id     UUID NOT NULL REFERENCES users(id),
    attended    BOOLEAN NOT NULL DEFAULT FALSE,
    joined_at   TIMESTAMP
);

-- ─── audit_events ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type  VARCHAR(50) NOT NULL,             -- AuditEventType (e.g. LOGIN_SUCCESS)
    user_id     UUID REFERENCES users(id),
    ip_address  VARCHAR(45),                      -- IPv4 or IPv6
    resource    VARCHAR(512),                     -- e.g. "/docs/download/abc123"
    detail      TEXT,                             -- JSON string with extra context
    severity    VARCHAR(20) DEFAULT 'info',       -- info / warning / critical
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_audit_events_event_type ON audit_events(event_type);
CREATE INDEX IF NOT EXISTS ix_audit_events_created_at ON audit_events(created_at);
