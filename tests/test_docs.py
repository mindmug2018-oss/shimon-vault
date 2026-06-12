# shimon-vault/app/routers/docs_router.py

"""
routers/docs_router.py — SecureDocs file vault endpoints

POST   /docs/upload          → upload file to S3, write metadata to RDS
GET    /docs/list             → list files the current user can access
GET    /docs/download/{id}   → generate 15-minute pre-signed S3 URL
DELETE /docs/{id}            → soft-delete
GET    /docs/{id}/versions   → list previous versions
"""

import json
import uuid as _uuid
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from pydantic import BaseModel
from slowapi import Limiter
from slowapi.util import get_remote_address
from sqlalchemy.orm import Session

import config
from auth import get_current_user, require_role
from database import get_read_db, get_write_db
from models import AuditEventType, Document, DocumentStatus, User, UserRole
from services.audit_service import write_event, write_security_incident
from services.s3_service import delete_s3_file, generate_presigned_url, upload_to_s3

router = APIRouter()
limiter = Limiter(key_func=get_remote_address)


# ─── Schemas ──────────────────────────────────────────────────────────────────

class DocumentOut(BaseModel):
    id:           str
    filename:     str
    content_type: str
    size_bytes:   int
    version:      int
    owner_id:     str
    created_at:   str

    class Config:
        from_attributes = True


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _parse_uuid(value: str, label: str = "id") -> _uuid.UUID:
    try:
        return _uuid.UUID(str(value))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=404, detail=f"Invalid {label}")


def _get_doc_or_404(db: Session, doc_id: str) -> Document:
    did = _parse_uuid(doc_id, "document id")
    doc = db.query(Document).filter(
        Document.id == did,
        Document.status == DocumentStatus.ACTIVE,
    ).first()
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")
    return doc


# ─── Routes ──────────────────────────────────────────────────────────────────

@router.post("/upload", status_code=status.HTTP_201_CREATED)
async def upload_document(
    request:      Request,
    file:         UploadFile = File(...),
    description:  Optional[str] = Form(None),
    db:           Session = Depends(get_write_db),
    current_user: User = Depends(require_role(UserRole.ADMIN, UserRole.EDITOR)),
):
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
    db:           Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
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
    request:      Request,
    doc_id:       str,
    db:           Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    ip = request.headers.get("x-forwarded-for", request.client.host if request.client else "unknown").split(",")[0].strip()
    doc = _get_doc_or_404(db, doc_id)

    if current_user.role == UserRole.VIEWER and str(doc.owner_id) != str(current_user.id):
        write_event(
            event_type=AuditEventType.DOC_ACCESS_DENIED,
            user_id=str(current_user.id),
            ip_address=ip,
            resource=f"/docs/download/{doc_id}",
            detail=json.dumps({"doc_owner": str(doc.owner_id)}),
            severity="warning",
        )
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
    doc_id:       str,
    db:           Session = Depends(get_write_db),
    current_user: User = Depends(require_role(UserRole.ADMIN)),
):
    doc = _get_doc_or_404(db, doc_id)

    doc.status     = DocumentStatus.DELETED
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
    doc_id:       str,
    db:           Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    did = _parse_uuid(doc_id, "document id")
    versions = db.query(Document).filter(
        Document.parent_id == did,
    ).order_by(Document.version.desc()).all()

    return [
        {"id": str(v.id), "version": v.version, "created_at": v.created_at.isoformat()}
        for v in versions
    ]