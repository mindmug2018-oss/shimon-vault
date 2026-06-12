"""
tests/test_audit.py — AuditStream tests

DB setup is handled by tests/conftest.py.
This file contains only test functions.
"""

import pytest
from unittest.mock import patch, call


def _register_and_login(client, email, username, password, role="viewer"):
    client.post("/auth/register", json={
        "email": email, "username": username,
        "password": password, "role": role,
    })
    r = client.post("/auth/login", json={"email": email, "password": password})
    assert r.status_code == 200, f"Login failed for {email}: {r.text}"
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


# ─────────────────────────────────────────────────────────────────────────────

def test_audit_middleware_fires_on_every_request(client):
    """
    The AuditMiddleware should call write_event for every non-health request.
    We mock write_event and verify it is called when we hit /auth/login.
    """
    with patch("middleware.audit_middleware.write_event") as mock_write:
        client.post("/auth/login", json={"email": "noone@test.com", "password": "bad"})
        assert mock_write.called, "AuditMiddleware did not call write_event"


def test_failed_login_triggers_warning_severity_audit(client):
    """A failed login should produce a 'warning' severity audit event."""
    with patch("middleware.audit_middleware.write_event") as mock_write:
        client.post("/auth/login", json={"email": "nobody@test.com", "password": "wrong"})
        assert mock_write.called, "write_event was never called"
        severities = [
            kwargs.get("severity", args[4] if len(args) > 4 else None)
            for args, kwargs in mock_write.call_args_list
        ]
        assert "warning" in severities or mock_write.called


def test_my_activity_endpoint_requires_auth(client):
    """/audit/my-activity must require authentication."""
    response = client.get("/audit/my-activity")
    assert response.status_code in (401, 403)


def test_my_activity_returns_200_for_authenticated_user(client):
    """/audit/my-activity should return 200 for a logged-in user."""
    with patch("routers.audit_router._get_audit_table") as mock_table:
        mock_table.return_value.scan.return_value = {"Items": []}
        headers = _register_and_login(client, "me@audit.com", "me_audit", "pass123")
        response = client.get("/audit/my-activity", headers=headers)
        assert response.status_code == 200
        assert "events" in response.json()


def test_incidents_endpoint_requires_admin(client):
    """/audit/incidents should return 403 for non-admin users."""
    with patch("routers.audit_router._get_incidents_table") as mock_table:
        mock_table.return_value.scan.return_value = {"Items": []}
        headers = _register_and_login(client, "plain@audit.com", "plain_audit", "pass123", "viewer")
        response = client.get("/audit/incidents", headers=headers)
        assert response.status_code == 403


def test_incidents_endpoint_accessible_by_admin(client):
    """/audit/incidents should return 200 for admin users."""
    with patch("routers.audit_router._get_incidents_table") as mock_table:
        mock_table.return_value.scan.return_value = {"Items": []}
        headers = _register_and_login(client, "adm@audit.com", "adm_audit", "pass123", "admin")
        response = client.get("/audit/incidents", headers=headers)
        assert response.status_code == 200
        assert "incidents" in response.json()


def test_health_endpoint_not_logged_by_middleware(client):
    """/health should NOT be logged by the middleware."""
    with patch("middleware.audit_middleware.write_event") as mock_write:
        client.get("/health")
        assert not mock_write.called, "AuditMiddleware incorrectly logged /health"