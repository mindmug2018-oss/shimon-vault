"""
tests/test_auth.py — Authentication tests

DB setup is handled by tests/conftest.py.
This file contains only test functions.
"""

import pytest
from unittest.mock import patch


# ─────────────────────────────────────────────────────────────────────────────

def test_register_new_user_returns_201_and_token(client):
    """Registering a new user should return HTTP 201 and an access token."""
    response = client.post("/auth/register", json={
        "email":    "alice@example.com",
        "username": "alice",
        "password": "SecurePass123",
        "role":     "viewer",
    })
    assert response.status_code == 201, response.text
    data = response.json()
    assert "access_token" in data
    assert data["token_type"] == "bearer"
    assert data["role"] == "viewer"
    assert data["username"] == "alice"


def test_register_duplicate_email_returns_400(client):
    """Registering the same email twice should return 400."""
    payload = {"email": "bob@example.com", "username": "bob", "password": "pass", "role": "viewer"}
    client.post("/auth/register", json=payload)
    response = client.post("/auth/register", json={**payload, "username": "bob2"})
    assert response.status_code == 400


def test_login_with_correct_credentials_returns_token(client):
    """Valid login should return a JWT access token."""
    client.post("/auth/register", json={
        "email": "carol@example.com", "username": "carol",
        "password": "MyPassword99", "role": "editor",
    })
    response = client.post("/auth/login", json={
        "email": "carol@example.com", "password": "MyPassword99",
    })
    assert response.status_code == 200, response.text
    data = response.json()
    assert "access_token" in data
    assert data["role"] == "editor"


def test_login_wrong_password_returns_401(client):
    """Wrong password should return 401 Unauthorized."""
    client.post("/auth/register", json={
        "email": "dan@example.com", "username": "dan",
        "password": "CorrectPassword", "role": "viewer",
    })
    response = client.post("/auth/login", json={
        "email": "dan@example.com", "password": "WrongPassword",
    })
    assert response.status_code == 401


def test_login_nonexistent_email_returns_401(client):
    """Login with an email that was never registered should return 401."""
    response = client.post("/auth/login", json={
        "email": "ghost@example.com", "password": "anything",
    })
    assert response.status_code == 401


def test_jwt_token_authenticates_protected_endpoint(client):
    """A valid JWT should allow access to an authenticated endpoint."""
    with patch("routers.audit_router._get_audit_table") as mock_table:
        mock_table.return_value.scan.return_value = {"Items": []}
        client.post("/auth/register", json={
            "email": "eve@example.com", "username": "eve",
            "password": "EvePass123", "role": "viewer",
        })
        login = client.post("/auth/login", json={
            "email": "eve@example.com", "password": "EvePass123",
        })
        token = login.json()["access_token"]
        response = client.get(
            "/audit/my-activity",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200


def test_protected_endpoint_without_token_returns_403(client):
    """Calling a protected endpoint with no token should return 401 or 403."""
    response = client.get("/audit/my-activity")
    assert response.status_code in (401, 403)


def test_health_endpoint_is_public(client):
    """/health must return 200 with no authentication."""
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "healthy"