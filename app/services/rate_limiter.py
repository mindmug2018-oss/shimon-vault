"""
services/rate_limiter.py — ShimonVault rate limiter

Why this exists alongside slowapi?
  slowapi handles HTTP-level rate limiting (429 responses on endpoints).
  This module handles BUSINESS-LOGIC rate limiting — tracking counts
  across requests to detect patterns like exfiltration attempts, and
  triggering security incidents when thresholds are crossed.

  Example: slowapi limits downloads to 10/60s per IP.
  This module counts consecutive downloads per user and fires an
  SNS incident alert when the exfiltration threshold is hit,
  even if the first few downloads were within the slowapi limit.
"""

import time
from collections import defaultdict
from threading import Lock

from services.audit_service import write_security_incident
from services.notify_service import notify_all

# Thread-safe counters
_lock = Lock()

# Structure: { "key": [timestamp, ...] }
_windows: dict[str, list] = defaultdict(list)

# Thresholds
EXFILTRATION_WINDOW_SECONDS = 60
EXFILTRATION_THRESHOLD = 10   # downloads within window = exfiltration attempt
LOGIN_FAILURE_WINDOW_SECONDS = 300  # 5 minutes
LOGIN_FAILURE_THRESHOLD = 20   # failures in 5 min = credential stuffing


def _clean_window(key: str, window_seconds: int) -> list:
    """Remove events older than window_seconds from the list."""
    now = time.time()
    cutoff = now - window_seconds
    with _lock:
        _windows[key] = [ts for ts in _windows[key] if ts > cutoff]
        return _windows[key]


def _record_event(key: str) -> None:
    """Record one event at the current timestamp."""
    with _lock:
        _windows[key].append(time.time())


def check_download_rate(ip: str, user_id: str) -> bool:
    """
    Record a file download attempt. Returns True if within safe limits.
    Returns False if the exfiltration threshold has been crossed.

    Side effect: fires SNS + Slack + Telegram incident alert when threshold is hit.
    """
    key = f"download:{ip}"
    _record_event(key)
    events = _clean_window(key, EXFILTRATION_WINDOW_SECONDS)
    count = len(events)

    if count >= EXFILTRATION_THRESHOLD:
        # Fire incident only on the exact threshold crossing, not every request after
        if count == EXFILTRATION_THRESHOLD:
            write_security_incident(
                incident_type="bulk_exfiltration",
                ip_address=ip,
                detail={
                    "downloads_in_window": count,
                    "window_seconds": EXFILTRATION_WINDOW_SECONDS,
                    "user_id": user_id,
                },
                user_id=user_id,
            )
            notify_all(
                f"*EXFILTRATION ATTEMPT -- ShimonVault*\n"
                f"Type: Bulk File Download\n"
                f"IP: `{ip}`\n"
                f"Files attempted: {count} in {EXFILTRATION_WINDOW_SECONDS}s\n"
                f"Action: Rate limit enforced, session flagged"
            )
        return False

    return True


def check_login_failure_rate(ip: str, email: str) -> dict:
    """
    Record a login failure. Returns a dict with:
      count: int   — total failures in the window
      alert: bool  — whether to send a Slack alert (crosses alert threshold)
      block: bool  — whether to invoke the block_ip Lambda

    Thresholds:
      20 failures in 5 min -> alert
      50 failures in 5 min -> block
    """
    key = f"login_fail:{ip}"
    _record_event(key)
    events = _clean_window(key, LOGIN_FAILURE_WINDOW_SECONDS)
    count = len(events)

    return {
        "count": count,
        "alert": count == 20,
        "block": count >= 50,
    }


def reset_login_failures(ip: str) -> None:
    """Clear the failure counter for an IP after a successful login."""
    with _lock:
        key = f"login_fail:{ip}"
        _windows.pop(key, None)


def get_download_count(ip: str) -> int:
    """Return how many downloads have been recorded for this IP in the current window."""
    events = _clean_window(f"download:{ip}", EXFILTRATION_WINDOW_SECONDS)
    return len(events)
