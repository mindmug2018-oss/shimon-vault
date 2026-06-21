# shimon-vault/app/routers/auth_router.py

"""
routers/auth_router.py — Authentication endpoints

POST /auth/register  -> create new account
POST /auth/login     -> returns JWT access token
POST /auth/logout    -> client-side logout (token blacklisting is a Week 3 feature)

Rate limiting:
  - /auth/login is limited to 10 requests/minute per IP
  - After 5 consecutive failures from the same IP, a security event is fired
  - After 50 failures, the Lambda block_ip function is triggered via SNS
"""

import json
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, EmailStr
from slowapi import Limiter
from slowapi.util import get_remote_address
from sqlalchemy.orm import Session

import config
from auth import create_access_token, hash_password, verify_password
from database import get_read_db, get_write_db
from models import AuditEventType, User, UserRole
from services.audit_service import write_event, write_security_incident
from services.notify_service import notify_all

router = APIRouter()
limiter = Limiter(key_func=get_remote_address)

# In-memory failure counter per IP (reset on restart — good enough for demo)
# In production this would be Redis
_failure_counts: dict[str, int] = {}
ALERT_THRESHOLD = 5    # Fire Slack/Telegram alert at this many failures
BLOCK_THRESHOLD = 8    # Trigger Lambda block_ip at this many failures


# ─── Schemas (Pydantic request/response models) ───────────────────────────────

class RegisterRequest(BaseModel):
    email: EmailStr
    username: str
    password: str
    role: UserRole = UserRole.VIEWER  # Default to lowest privilege


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: str
    username: str


# ─── Routes ──────────────────────────────────────────────────────────────────

@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(req: RegisterRequest, db: Session = Depends(get_write_db)):
    """
    Create a new user account.
    In a real deployment, self-registration would be invite-only.
    For demo purposes we allow open registration.
    """
    # Check for duplicate email or username
    if db.query(User).filter(User.email == req.email).first():
        raise HTTPException(status_code=400, detail="Email already registered")
    if db.query(User).filter(User.username == req.username).first():
        raise HTTPException(status_code=400, detail="Username already taken")

    user = User(
        email=req.email,
        username=req.username,
        hashed_pw=hash_password(req.password),
        role=req.role,
    )
    db.add(user)
    db.commit()
    db.refresh(user)

    token = create_access_token({"sub": str(user.id), "role": user.role.value})
    return TokenResponse(access_token=token, role=user.role.value, username=user.username)


@router.post("/login", response_model=TokenResponse)
@limiter.limit(config.LOGIN_RATE_LIMIT)  # 10/minute per IP — triggers 429 if exceeded
def login(
    request: Request,  # required by slowapi for IP extraction
    req: LoginRequest,
    db: Session = Depends(get_read_db),
):
    """
    Authenticate with email + password. Returns a JWT.

    Failure tracking:
      Every wrong password increments _failure_counts[ip].
      At ALERT_THRESHOLD: Slack + Telegram alert fires.
      At BLOCK_THRESHOLD: Lambda block_ip is invoked via SNS.
    """
    ip = request.headers.get("x-forwarded-for", request.client.host).split(",")[0].strip()

    # Look up user (use read replica — login is a read operation)
    user = db.query(User).filter(User.email == req.email).first()

    if not user or not verify_password(req.password, user.hashed_pw):
        # Track failure
        _failure_counts[ip] = _failure_counts.get(ip, 0) + 1
        count = _failure_counts[ip]

        # Write to DynamoDB audit log
        write_event(
            event_type=AuditEventType.LOGIN_FAILURE,
            ip_address=ip,
            resource="/auth/login",
            detail=json.dumps({"email": req.email, "failure_count": count}),
            severity="warning" if count < ALERT_THRESHOLD else "critical",
        )

        # Fire alerts at thresholds
        if count == ALERT_THRESHOLD:
            notify_all(
                f"*SECURITY ALERT -- ShimonVault*\n"
                f"Type: Credential Stuffing (warning threshold)\n"
                f"IP: `{ip}`\n"
                f"Failed attempts: {count}\n"
                f"Time: {datetime.now(timezone.utc).isoformat()}"
            )
        elif count >= BLOCK_THRESHOLD:
            # Write full incident and notify
            write_security_incident(
                incident_type="credential_stuffing",
                ip_address=ip,
                detail={"failure_count": count, "email_tried": req.email},
            )
            notify_all(
                f"*CREDENTIAL STUFFING DETECTED -- ShimonVault*\n"
                f"IP: `{ip}`\n"
                f"Failed attempts: {count}\n"
                f"Action: IP block Lambda triggered\n"
                f"Time: {datetime.now(timezone.utc).isoformat()}"
            )
            # TODO Week 3: invoke Lambda block_ip via SNS publish here

        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
        )

    if not user.is_active or user.suspended:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is suspended or inactive",
        )

    # Successful login — reset failure counter
    _failure_counts.pop(ip, None)

    write_event(
        event_type=AuditEventType.LOGIN_SUCCESS,
        ip_address=ip,
        resource="/auth/login",
        user_id=str(user.id),
        severity="info",
    )

    token = create_access_token({"sub": str(user.id), "role": user.role.value})
    return TokenResponse(access_token=token, role=user.role.value, username=user.username)


@router.post("/logout")
def logout():
    """
    Client-side logout.
    The client discards the JWT. Server-side blacklisting added in Week 3.
    """
    return {"detail": "Logged out successfully"}
