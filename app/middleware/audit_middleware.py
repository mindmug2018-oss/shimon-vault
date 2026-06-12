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
from datetime import datetime

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware

from services.audit_service import write_event
from models import AuditEventType


# Paths that are too noisy to log every time
_SKIP_PATHS = {"/health", "/metrics", "/favicon.ico"}

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

        return response