# shimon-vault/app/routers/meetings_router.py

"""
routers/meetings_router.py — ShimonMeet scheduling endpoints

POST   /meetings/create       -> create meeting, schedule EventBridge rule (Week 3)
GET    /meetings/list         -> list upcoming meetings for current user
GET    /meetings/{id}         -> get meeting details + join token
PUT    /meetings/{id}         -> update meeting
DELETE /meetings/{id}         -> cancel meeting
POST   /meetings/{id}/join    -> record attendance, validate join token
GET    /meetings/{id}/archive -> get past meeting attendance record
"""

import secrets
import uuid as _uuid
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from auth import get_current_user, require_role
from database import get_read_db, get_write_db
from models import AuditEventType, Meeting, MeetingStatus, Participant, User, UserRole
from services.audit_service import write_event

router = APIRouter()


# ─── Schemas ──────────────────────────────────────────────────────────────────

class MeetingCreate(BaseModel):
    title: str
    description: Optional[str] = None
    scheduled_at: datetime       # ISO-8601 format: "2026-06-03T14:00:00Z"
    ends_at: datetime
    participant_ids: List[str] = []


class MeetingOut(BaseModel):
    id: str
    title: str
    description: Optional[str]
    organizer_id: str
    join_token: str
    status: str
    scheduled_at: str
    ends_at: str
    created_at: str


# ─── Routes ──────────────────────────────────────────────────────────────────

@router.post("/create", response_model=MeetingOut, status_code=status.HTTP_201_CREATED)
def create_meeting(
    req: MeetingCreate,
    db: Session = Depends(get_write_db),
    current_user: User = Depends(require_role(UserRole.ADMIN, UserRole.EDITOR)),
):
    """
    Create a meeting. A unique join token is generated.
    EventBridge scheduling for reminders is added in Week 3.
    """
    if req.scheduled_at <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail="scheduled_at must be in the future")
    if req.ends_at <= req.scheduled_at:
        raise HTTPException(status_code=400, detail="ends_at must be after scheduled_at")

    meeting = Meeting(
        title=req.title,
        description=req.description,
        organizer_id=current_user.id,
        join_token=secrets.token_hex(32),  # 64-char random hex token
        scheduled_at=req.scheduled_at,
        ends_at=req.ends_at,
    )
    db.add(meeting)
    db.flush()  # flush to get meeting.id before adding participants

    for uid in req.participant_ids:
        db.add(Participant(meeting_id=meeting.id, user_id=uid))

    db.commit()
    db.refresh(meeting)

    write_event(
        event_type=AuditEventType.MEETING_CREATE,
        user_id=str(current_user.id),
        resource=f"/meetings/{meeting.id}",
        severity="info",
    )

    return _meeting_to_out(meeting)


@router.get("/list", response_model=List[MeetingOut])
def list_meetings(
    db: Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    """List upcoming and active meetings for the current user."""
    if current_user.role == UserRole.ADMIN:
        meetings = db.query(Meeting).filter(
            Meeting.status.in_([MeetingStatus.SCHEDULED, MeetingStatus.ACTIVE])
        ).all()
    else:
        # Non-admins only see meetings they organize or are invited to
        organized = db.query(Meeting).filter(
            Meeting.organizer_id == current_user.id,
            Meeting.status.in_([MeetingStatus.SCHEDULED, MeetingStatus.ACTIVE]),
        ).all()
        invited_ids = [
            p.meeting_id for p in
            db.query(Participant).filter(Participant.user_id == current_user.id).all()
        ]
        invited = db.query(Meeting).filter(
            Meeting.id.in_(invited_ids),
            Meeting.status.in_([MeetingStatus.SCHEDULED, MeetingStatus.ACTIVE]),
        ).all()
        meetings = list({m.id: m for m in organized + invited}.values())

    return [_meeting_to_out(m) for m in meetings]


@router.get("/{meeting_id}", response_model=MeetingOut)
def get_meeting(
    meeting_id: str,
    db: Session = Depends(get_read_db),
    current_user: User = Depends(get_current_user),
):
    meeting = _get_or_404(db, meeting_id)
    _check_access(meeting, current_user, db)
    return _meeting_to_out(meeting)


@router.put("/{meeting_id}", response_model=MeetingOut)
def update_meeting(
    meeting_id: str,
    req: MeetingCreate,
    db: Session = Depends(get_write_db),
    current_user: User = Depends(get_current_user),
):
    meeting = _get_or_404(db, meeting_id)
    if str(meeting.organizer_id) != str(current_user.id) and current_user.role != UserRole.ADMIN:
        raise HTTPException(status_code=403, detail="Only the organizer or admin can update")

    meeting.title = req.title
    meeting.description = req.description
    meeting.scheduled_at = req.scheduled_at
    meeting.ends_at = req.ends_at
    db.commit()
    db.refresh(meeting)
    return _meeting_to_out(meeting)


@router.delete("/{meeting_id}")
def cancel_meeting(
    meeting_id: str,
    db: Session = Depends(get_write_db),
    current_user: User = Depends(get_current_user),
):
    """
    Cancel a meeting. Allowed for the meeting's ORGANIZER or an ADMIN.

    Anyone else — including a viewer hitting a non-existent or malformed id —
    gets 403 without revealing whether the meeting exists, so the access-control
    demo reports a clean 403 instead of a 500. An admin hitting a genuinely
    missing meeting still gets a 404.
    """
    meeting = _get_or_none(db, meeting_id)
    is_admin = current_user.role == UserRole.ADMIN
    is_organizer = meeting is not None and str(meeting.organizer_id) == str(current_user.id)

    if not (is_admin or is_organizer):
        raise HTTPException(status_code=403, detail="Only the organizer or admin can cancel")
    if meeting is None:
        raise HTTPException(status_code=404, detail="Meeting not found")

    meeting.status = MeetingStatus.CANCELLED
    db.commit()

    write_event(
        event_type=AuditEventType.MEETING_CANCEL,
        user_id=str(current_user.id),
        resource=f"/meetings/{meeting_id}",
        severity="info",
    )
    return {"detail": "Meeting cancelled"}


@router.post("/{meeting_id}/join")
def join_meeting(
    meeting_id: str,
    request: Request,
    token: str,
    db: Session = Depends(get_write_db),
    current_user: User = Depends(get_current_user),
):
    """
    Join a meeting by presenting the join token.
    Token replay (using an expired token) is detected and logged.
    """
    ip = request.headers.get("x-forwarded-for", request.client.host).split(",")[0].strip()
    meeting = _get_or_404(db, meeting_id)

    # Validate token
    if meeting.join_token != token:
        write_event(
            event_type=AuditEventType.TOKEN_REPLAY,
            user_id=str(current_user.id),
            ip_address=ip,
            resource=f"/meetings/{meeting_id}/join",
            severity="warning",
        )
        raise HTTPException(status_code=401, detail="Invalid join token")

    # Check meeting is still active
    now = datetime.now(timezone.utc)
    if meeting.status == MeetingStatus.EXPIRED or now > meeting.ends_at:
        write_event(
            event_type=AuditEventType.TOKEN_REPLAY,
            user_id=str(current_user.id),
            ip_address=ip,
            resource=f"/meetings/{meeting_id}/join",
            detail="expired token replay",
            severity="warning",
        )
        raise HTTPException(status_code=401, detail="Meeting has ended")

    # Record attendance
    participant = db.query(Participant).filter(
        Participant.meeting_id == meeting_id,
        Participant.user_id == current_user.id,
    ).first()
    if participant:
        participant.attended = True
        participant.joined_at = now
    else:
        db.add(Participant(
            meeting_id=meeting.id,
            user_id=current_user.id,
            attended=True,
            joined_at=now,
        ))

    db.commit()

    write_event(
        event_type=AuditEventType.MEETING_JOIN,
        user_id=str(current_user.id),
        ip_address=ip,
        resource=f"/meetings/{meeting_id}/join",
        severity="info",
    )

    return {"detail": "Joined successfully", "meeting_title": meeting.title}


@router.get("/{meeting_id}/archive")
def get_meeting_archive(
    meeting_id: str,
    db: Session = Depends(get_read_db),
    current_user: User = Depends(require_role(UserRole.ADMIN, UserRole.EDITOR)),
):
    """Get past meeting attendance. Admin/Editor only."""
    meeting = _get_or_404(db, meeting_id)
    participants = db.query(Participant).filter(Participant.meeting_id == meeting_id).all()
    return {
        "meeting_id": meeting_id,
        "title": meeting.title,
        "attended_count": sum(1 for p in participants if p.attended),
        "total_invited": len(participants),
        "participants": [
            {
                "user_id": str(p.user_id),
                "attended": p.attended,
                "joined_at": p.joined_at.isoformat() if p.joined_at else None,
            }
            for p in participants
        ],
    }


# ─── Helpers ─────────────────────────────────────────────────────────────────

def _get_or_none(db: Session, meeting_id: str) -> Optional[Meeting]:
    """Return the meeting, or None if the id is malformed or missing (never 500)."""
    try:
        mid = _uuid.UUID(str(meeting_id))
    except (ValueError, AttributeError):
        return None
    return db.query(Meeting).filter(Meeting.id == mid).first()


def _get_or_404(db: Session, meeting_id: str) -> Meeting:
    meeting = _get_or_none(db, meeting_id)
    if not meeting:
        raise HTTPException(status_code=404, detail="Meeting not found")
    return meeting


def _check_access(meeting: Meeting, user: User, db: Session):
    if user.role == UserRole.ADMIN:
        return
    if str(meeting.organizer_id) == str(user.id):
        return
    is_participant = db.query(Participant).filter(
        Participant.meeting_id == meeting.id,
        Participant.user_id == user.id,
    ).first()
    if not is_participant:
        raise HTTPException(status_code=403, detail="Access denied")


def _meeting_to_out(m: Meeting) -> MeetingOut:
    return MeetingOut(
        id=str(m.id),
        title=m.title,
        description=m.description,
        organizer_id=str(m.organizer_id),
        join_token=m.join_token,
        status=m.status.value,
        scheduled_at=m.scheduled_at.isoformat(),
        ends_at=m.ends_at.isoformat(),
        created_at=m.created_at.isoformat(),
    )
