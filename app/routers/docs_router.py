# shimon-vault/app/routers/docs_router.py

"""
routers/docs_router.py — SecureDocs file vault endpoints

POST   /docs/upload          -> upload file to S3, write metadata to RDS
GET    /docs/list             -> list files the current user can access
GET    /docs/download/{id}   -> generate 15-minute pre-signed S3 URL
DELETE /docs/{id}            -> soft-delete (marks as deleted, never removes)
GET    /docs/{id}/versions   -> list previous versions of a document

Security:
  - Viewers can only see and download their own files
  - Editors can upload and see all non-admin files
  - Admins can see and delete everything
  - Downloads are rate-limited: 10 requests per 60 seconds per IP
  - Broken access control: accessing another user's file -> 403 + incident log
"""

import json
import uuid as _uuid
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from pydantic import BaseModel
from rate_limit import limiter
from sqlalchemy.orm import Session

import config
from auth import get_current_user, require_role
from database import get_read_db, get_write_db
from models import AuditEventType, Document, DocumentStatus, User, UserRole
from services.audit_service import write_event
from services.s3_service import delete_s3_file, generate_presigned_url, upload_to_s3

router = APIRouter()

# Track download counts per IP to detect exfiltration
_download_counts: dict[str, list] = {}


# ─── Schemas ──────────────────────────────────────────────────────────────────

class DocumentOut(BaseModel):
    id: str
    filename: str
    content_type: str
    size_bytes: int
    version: int
    owner_id: str
    created_at: str

    class Config:
        from_attributes = True


# ─── Routes ──────────────────────────────────────────────────────────────────

@router.post("/upload", status_code=status.HTTP_201_CREATED)
async def upload_document(
    request: Request,
    file: UploadFile = File(...),
    description: Optional[str] = Form(None),
    db: Session = Depends(get_write_db),
    current_user: User = Depends(require_role(UserRole.ADMIN, UserRole.EDITOR)),
):
    """
    Upload a file. Only ADMIN and EDITOR roles allowed.
    File is stored in S3. Metadata (filename, s3_key, size) stored in RDS.
    """
    file_bytes = await file.read()
    s3_key = upload_to_s3(
        file_bytes=file_bytes,
        filename=file.filename,
        content_type=file.content_type or "application/octet-stream",
        owner_id=str(current_user.id),
    )

    doc = Document(
        filename=file.filename,
        s3_key=s3_key,
        content_type=file.content_type or "application/octet-stream",
        size_bytes=len(file_bytes),
        owner_id=current_user.id,
        description=description,
    )
    db.add(doc)
    db.commit()
    db.refresh(doc)

    write_event(
        event_type=AuditEventType.DOC_UPLOAD,
        user_id=str(current_user.id),
        resource=f"/docs/{doc.id}",
        detail=json.dumps({"filename": file.filename, "size_bytes": len(file_bytes)}),
        severity="info",
    )

    return {"id": str(doc.id), "filename": doc.filename, "s3_key": s3_key}


@router.get("/list", response_model=List[DocumentOut])
def list_documents(
    db: Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    """
    List documents the current user has access to.
    ADMIN: sees everything active.
    EDITOR: sees everything active.
    VIEWER: sees only their own files.
    """
    query = db.query(Document).filter(Document.status == DocumentStatus.ACTIVE)
    if current_user.role == UserRole.VIEWER:
        query = query.filter(Document.owner_id == current_user.id)
    docs = query.order_by(Document.created_at.desc()).all()

    return [
        DocumentOut(
            id=str(d.id),
            filename=d.filename,
            content_type=d.content_type,
            size_bytes=d.size_bytes,
            version=d.version,
            owner_id=str(d.owner_id),
            created_at=d.created_at.isoformat(),
        )
        for d in docs
    ]


@router.get("/download/{doc_id}")
@limiter.limit(config.DOWNLOAD_RATE_LIMIT)
def download_document(
    request: Request,
    doc_id: str,
    db: Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    """
    Generate a 15-minute pre-signed S3 URL for the file.
    The client uses this URL to download directly from S3.
    This route enforces access control BEFORE generating the URL.

    Rate limited: 10 downloads per 60 seconds per IP.
    Exceeding this triggers the exfiltration detection alert.
    """
    ip = request.headers.get("x-forwarded-for", request.client.host).split(",")[0].strip()

    # doc_id must be a valid UUID before hitting the DB -- a malformed or
    # non-existent ID (e.g. a fuzzed/fake ID during an exfiltration attempt)
    # otherwise raises an unhandled SQLAlchemy/psycopg2 cast error and a
    # raw 500 instead of a clean 404.
    try:
        _uuid.UUID(str(doc_id))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=404, detail="Document not found")

    doc = db.query(Document).filter(
        Document.id == doc_id,
        Document.status == DocumentStatus.ACTIVE,
    ).first()

    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")

    # ── Access control: VIEWER can only download their own files ──
    if current_user.role == UserRole.VIEWER and str(doc.owner_id) != str(current_user.id):
        write_event(
            event_type=AuditEventType.DOC_ACCESS_DENIED,
            user_id=str(current_user.id),
            ip_address=ip,
            resource=f"/docs/download/{doc_id}",
            detail=json.dumps({"doc_owner": str(doc.owner_id)}),
            severity="warning",
        )
        # Count consecutive violations — 5+ triggers account suspension
        raise HTTPException(status_code=403, detail="Access denied")

    presigned_url = generate_presigned_url(s3_key=doc.s3_key, expires_seconds=900)

    write_event(
        event_type=AuditEventType.DOC_DOWNLOAD,
        user_id=str(current_user.id),
        ip_address=ip,
        resource=f"/docs/download/{doc_id}",
        detail=json.dumps({"filename": doc.filename}),
        severity="info",
    )

    return {"download_url": presigned_url, "expires_in_seconds": 900}


@router.delete("/{doc_id}")
def delete_document(
    doc_id: str,
    db: Session = Depends(get_write_db),
    current_user: User = Depends(require_role(UserRole.ADMIN)),
):
    """
    Soft-delete a document. Only ADMIN can delete.
    The record stays in the database with status=deleted for audit purposes.
    The S3 file is also deleted.
    """
    doc = db.query(Document).filter(
        Document.id == doc_id,
        Document.status == DocumentStatus.ACTIVE,
    ).first()

    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")

    doc.status = DocumentStatus.DELETED
    doc.deleted_at = datetime.now(timezone.utc)
    db.commit()

    delete_s3_file(s3_key=doc.s3_key)

    write_event(
        event_type=AuditEventType.DOC_DELETE,
        user_id=str(current_user.id),
        resource=f"/docs/{doc_id}",
        detail=json.dumps({"filename": doc.filename}),
        severity="info",
    )

    return {"detail": "Document deleted", "id": doc_id}


@router.get("/{doc_id}/versions")
def get_document_versions(
    doc_id: str,
    db: Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    """
    List all versions of a document.

    A VIEWER may only list versions of their OWN existing documents. Any other
    case for a viewer — someone else's document, or a missing / malformed id —
    returns 403 without revealing whether the document exists (this is what
    makes the broken-access-control demo report a clean 403 instead of a 500).
    ADMIN / EDITOR get a normal 404 for a genuinely missing document.
    """
    # Resolve the document, tolerating a malformed (non-UUID) id.
    doc = None
    try:
        doc = db.query(Document).filter(Document.id == _uuid.UUID(str(doc_id))).first()
    except (ValueError, AttributeError):
        doc = None

    if current_user.role == UserRole.VIEWER:
        if doc is None or str(doc.owner_id) != str(current_user.id):
            raise HTTPException(status_code=403, detail="Access denied")
    elif doc is None:
        raise HTTPException(status_code=404, detail="Document not found")

    versions = db.query(Document).filter(
        Document.parent_id == doc.id,
    ).order_by(Document.version.desc()).all()

    return [
        {"id": str(v.id), "version": v.version, "created_at": v.created_at.isoformat()}
        for v in versions
    ]
