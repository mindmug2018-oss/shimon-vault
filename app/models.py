# shimon-vault/app/models.py

"""
models.py — ShimonVault ORM models

Tables:
  users           -> platform accounts (admin / editor / viewer)
  documents       -> file metadata (the actual bytes live in S3)
  meetings        -> scheduled virtual meetings
  participants    -> who is invited to which meeting
  audit_events    -> every action logged here AND in DynamoDB
                     (DynamoDB for fast queries, PostgreSQL for reports)

All tables use UUID primary keys — never sequential integers.
Sequential integers let attackers enumerate records by just incrementing
the ID. UUIDs are unguessable.
"""

import uuid
from enum import Enum as PyEnum

from sqlalchemy import (
    Boolean, Column, DateTime, Enum, ForeignKey,
    Integer, String, Text, func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from database import Base


# ─── Enums ────────────────────────────────────────────────────────────────────

class UserRole(str, PyEnum):
    ADMIN = "admin"
    EDITOR = "editor"
    VIEWER = "viewer"


class DocumentStatus(str, PyEnum):
    ACTIVE = "active"
    DELETED = "deleted"   # soft delete — never truly remove from DB


class MeetingStatus(str, PyEnum):
    SCHEDULED = "scheduled"
    ACTIVE = "active"
    EXPIRED = "expired"
    CANCELLED = "cancelled"


class AuditEventType(str, PyEnum):
    LOGIN_SUCCESS = "login_success"
    LOGIN_FAILURE = "login_failure"
    LOGOUT = "logout"
    DOC_UPLOAD = "doc_upload"
    DOC_DOWNLOAD = "doc_download"
    DOC_DELETE = "doc_delete"
    DOC_ACCESS_DENIED = "doc_access_denied"
    MEETING_CREATE = "meeting_create"
    MEETING_JOIN = "meeting_join"
    MEETING_CANCEL = "meeting_cancel"
    TOKEN_REPLAY = "token_replay"
    RATE_LIMIT_HIT = "rate_limit_hit"
    SUSPICIOUS = "suspicious"


# ─── User ─────────────────────────────────────────────────────────────────────

class User(Base):
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String(255), unique=True, nullable=False, index=True)
    username = Column(String(100), unique=True, nullable=False)
    hashed_pw = Column(String(255), nullable=False)
    role = Column(Enum(UserRole), nullable=False, default=UserRole.VIEWER)
    is_active = Column(Boolean, default=True, nullable=False)
    suspended = Column(Boolean, default=False, nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now())

    documents = relationship("Document", back_populates="owner", foreign_keys="Document.owner_id")
    participations = relationship("Participant", back_populates="user")
    audit_events = relationship("AuditEvent", back_populates="user")

    def __repr__(self):
        return f"<User {self.username} role={self.role}>"


# ─── Document ─────────────────────────────────────────────────────────────────

class Document(Base):
    __tablename__ = "documents"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    filename = Column(String(255), nullable=False)
    s3_key = Column(String(512), nullable=False)          # path inside S3 bucket
    content_type = Column(String(100), nullable=False)
    size_bytes = Column(Integer, nullable=False)
    version = Column(Integer, default=1, nullable=False)
    parent_id = Column(UUID(as_uuid=True), ForeignKey("documents.id"), nullable=True)
    owner_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    status = Column(Enum(DocumentStatus), default=DocumentStatus.ACTIVE, nullable=False)
    description = Column(Text, nullable=True)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    deleted_at = Column(DateTime, nullable=True)

    owner = relationship("User", back_populates="documents", foreign_keys=[owner_id])
    versions = relationship("Document", back_populates="parent", foreign_keys=[parent_id])
    parent = relationship(
        "Document", back_populates="versions",
        foreign_keys=[parent_id], remote_side=[id]
    )

    def __repr__(self):
        return f"<Document {self.filename} v{self.version}>"


# ─── Meeting ──────────────────────────────────────────────────────────────────

class Meeting(Base):
    __tablename__ = "meetings"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    organizer_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    join_token = Column(String(64), unique=True, nullable=False)  # random hex token
    status = Column(Enum(MeetingStatus), default=MeetingStatus.SCHEDULED, nullable=False)
    scheduled_at = Column(DateTime, nullable=False)
    ends_at = Column(DateTime, nullable=False)
    eventbridge_rule_name = Column(String(255), nullable=True)  # for cancellation
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    archived_at = Column(DateTime, nullable=True)

    organizer = relationship("User", foreign_keys=[organizer_id])
    participants = relationship("Participant", back_populates="meeting")

    def __repr__(self):
        return f"<Meeting '{self.title}' at {self.scheduled_at}>"


# ─── Participant ──────────────────────────────────────────────────────────────

class Participant(Base):
    __tablename__ = "participants"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    meeting_id = Column(UUID(as_uuid=True), ForeignKey("meetings.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    attended = Column(Boolean, default=False, nullable=False)
    joined_at = Column(DateTime, nullable=True)

    meeting = relationship("Meeting", back_populates="participants")
    user = relationship("User", back_populates="participations")


# ─── Audit Event ──────────────────────────────────────────────────────────────

class AuditEvent(Base):
    __tablename__ = "audit_events"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    event_type = Column(Enum(AuditEventType), nullable=False, index=True)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=True)
    ip_address = Column(String(45), nullable=True)   # IPv4 or IPv6
    resource = Column(String(512), nullable=True)    # e.g. "/docs/download/abc123"
    detail = Column(Text, nullable=True)             # JSON string with extra context
    severity = Column(String(20), default="info")    # info / warning / critical
    created_at = Column(DateTime, server_default=func.now(), nullable=False, index=True)

    user = relationship("User", back_populates="audit_events")

    def __repr__(self):
        return f"<AuditEvent {self.event_type} at {self.created_at}>"
