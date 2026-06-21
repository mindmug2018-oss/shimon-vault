# shimon-vault/app/middleware/audit_middleware.py
"""
middleware/audit_middleware.py — ShimonVault request audit logger
Every HTTP request that hits the FastAPI app is intercepted here.
Before returning the response, this middleware writes a record to
the DynamoDB audit-log table via audit_service.
Why middleware and not individual route handlers?
  - Routes can forget to log. Middleware never forgets.
  - It's one consistent place to capture IP, path, method, status code.
  - Security events (403, 401, 429) are captured automatically.
"""
import json
import uuid as _uuid
from typing import Optional

from fastapi import Request
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

import config
from database import get_write_db
from models import AuditEventType, User
from services.audit_service import write_event, write_security_incident

# Paths that are too noisy to log every time
_SKIP_PATHS = {"/health", "/metrics", "/favicon.ico"}

# After this many access-control violations (403s) by one user, suspend them.
_SUSPEND_THRESHOLD = 5
_violation_counts: dict[str, int] = {}


def _user_id_from_request(request: Request) -> Optional[str]:
    """Pull the user id (JWT 'sub') from the Authorization header, or None."""
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return None
    token = auth.split(" ", 1)[1].strip()
    try:
        payload = jwt.decode(
            token, config.JWT_SECRET_KEY, algorithms=[config.JWT_ALGORITHM]
        )
        return payload.get("sub")
    except JWTError:
        return None


def _record_violation_and_maybe_suspend(user_id: str, ip: str) -> None:
    """
    Count one access-control violation for this user. Once the count reaches
    _SUSPEND_THRESHOLD, set users.suspended = True (auth.get_current_user then
    blocks the account). Best-effort: any failure is logged, never raised.
    """
    _violation_counts[user_id] = _violation_counts.get(user_id, 0) + 1
    if _violation_counts[user_id] < _SUSPEND_THRESHOLD:
        return

    gen = get_write_db()
    db = next(gen)
    try:
        user = db.query(User).filter(User.id == _uuid.UUID(str(user_id))).first()
        if user and not user.suspended:
            user.suspended = True
            db.commit()
            write_security_incident(
                incident_type="broken_access_control",
                ip_address=ip,
                detail={"user_id": user_id, "violations": _violation_counts[user_id]},
                user_id=user_id,
            )
    finally:
        gen.close()

# Map HTTP status codes to event types for security-relevant responses
_STATUS_EVENT_MAP = {
    401: AuditEventType.LOGIN_FAILURE,
    403: AuditEventType.DOC_ACCESS_DENIED,
    429: AuditEventType.RATE_LIMIT_HIT,
}


class AuditMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # Skip health checks and metrics scrapes — they happen every 30s
        if request.url.path in _SKIP_PATHS:
            return await call_next(request)
        # Call the actual route handler
        response = await call_next(request)
        # Determine severity based on HTTP status
        status_code = response.status_code
        if status_code >= 500:
            severity = "critical"
        elif status_code in (401, 403, 429):
            severity = "warning"
        else:
            severity = "info"
        # Map status to event type (default to suspicious for 4xx we don't recognize)
        if status_code in _STATUS_EVENT_MAP:
            event_type = _STATUS_EVENT_MAP[status_code]
        elif 400 <= status_code < 500:
            event_type = AuditEventType.SUSPICIOUS
        else:
            # For 2xx/3xx, use a path-based heuristic
            path = request.url.path
            if "/docs/download" in path:
                event_type = AuditEventType.DOC_DOWNLOAD
            elif "/docs/upload" in path or (path.startswith("/docs") and request.method == "POST"):
                event_type = AuditEventType.DOC_UPLOAD
            elif "/auth/login" in path:
                event_type = AuditEventType.LOGIN_SUCCESS
            elif "/auth/logout" in path:
                event_type = AuditEventType.LOGOUT
            elif "/meetings" in path and "join" in path:
                event_type = AuditEventType.MEETING_JOIN
            else:
                # Generic info event — still logged for the full audit trail
                event_type = AuditEventType.LOGIN_SUCCESS  # reuse as generic "action"
        # Extract client IP. X-Forwarded-For is set by ALB / Cloudflare.
        ip = (
            request.headers.get("x-forwarded-for", "").split(",")[0].strip()
            or request.client.host
        )
        detail = json.dumps({
            "method": request.method,
            "path":   request.url.path,
            "status": status_code,
        })
        # Fire-and-forget write — we do NOT await or let it block the response
        # If DynamoDB is down, the error is logged to stdout but never raises
        try:
            write_event(
                event_type=event_type,
                ip_address=ip,
                resource=request.url.path,
                detail=detail,
                severity=severity,
            )
        except Exception as exc:
            print(f"[AuditMiddleware] Failed to write audit event: {exc}")

        # Broken-access-control auto-suspend: count 403s per user and suspend
        # the account once it crosses the threshold. Wrapped so it can never
        # affect the response.
        if status_code == 403:
            try:
                uid = _user_id_from_request(request)
                if uid:
                    _record_violation_and_maybe_suspend(uid, ip)
            except Exception as exc:
                print(f"[AuditMiddleware] suspension check failed: {exc}")

        return response
