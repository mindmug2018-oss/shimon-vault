"""
tests/conftest.py

Shared test configuration for all test files.
Handles: env vars, DB setup, rate limiter bypass, shared fixtures.
"""

import os
import sys
import pytest

# ── Env vars BEFORE any app import ───────────────────────────────────────────
os.environ["WRITE_DB_URL"]               = "sqlite:///./test_shared.db"
os.environ["READ_DB_URL"]                = "sqlite:///./test_shared.db"
os.environ["JWT_SECRET_KEY"]             = "test-secret-key-not-for-production-use!!"
os.environ["AWS_REGION"]                 = "ap-northeast-2"
os.environ["S3_BUCKET_DOCS"]             = "test-bucket-docs"
os.environ["S3_BUCKET_REPORTS"]          = "test-bucket-reports"
os.environ["DYNAMODB_AUDIT_TABLE"]       = "test-audit-log"
os.environ["DYNAMODB_INCIDENTS_TABLE"]   = "test-incidents"
os.environ["DYNAMODB_MEETINGS_TABLE"]    = "test-meetings"
os.environ["LAMBDA_BLOCK_IP_NAME"]       = "test-block-ip"
os.environ["SNS_TOPIC_SECURITY_ARN"]     = "arn:aws:sns:ap-northeast-2:123456789012:test"
os.environ["SNS_TOPIC_MEETING_REMINDERS"]= "arn:aws:sns:ap-northeast-2:123456789012:test-mtg"
os.environ["SLACK_WEBHOOK_URL"]          = "https://hooks.slack.com/test"
os.environ["TELEGRAM_BOT_TOKEN"]         = "123456:test"
os.environ["TELEGRAM_CHAT_ID"]           = "123456"
os.environ["APP_SECURITY_GROUP_ID"]      = "sg-test"
os.environ["NACL_ID"]                    = "acl-test"

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

# ── Shared DB engine ──────────────────────────────────────────────────────────
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

engine = create_engine(
    "sqlite:///./test_shared.db",
    connect_args={"check_same_thread": False},
)
TestSession = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def override_db():
    db = TestSession()
    try:
        yield db
    finally:
        db.close()


# ── Import app and patch rate limiters BEFORE any test runs ──────────────────
from database import Base, get_write_db, get_read_db
from main import app

app.dependency_overrides[get_write_db] = override_db
app.dependency_overrides[get_read_db]  = override_db

# Patch ALL rate limiters to be no-ops in tests.
# There are two: one in main.py and one in auth_router.py and docs_router.py.
# The simplest fix: replace the limit decorator with a no-op.
from unittest.mock import MagicMock
import slowapi

_real_limiter_limit = slowapi.Limiter.limit

def _noop_limit(self, *args, **kwargs):
    """Return a no-op decorator so rate limits never fire during tests."""
    def decorator(func):
        return func
    return decorator

slowapi.Limiter.limit = _noop_limit


# ── Fixtures ──────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def reset_db():
    """Fresh tables for every test."""
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client():
    from fastapi.testclient import TestClient
    with TestClient(app) as c:
        yield c


@pytest.fixture
def admin_headers(client):
    client.post("/auth/register", json={
        "email": "admin@test.com", "username": "testadmin",
        "password": "AdminPass123", "role": "admin",
    })
    r = client.post("/auth/login", json={
        "email": "admin@test.com", "password": "AdminPass123",
    })
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.fixture
def editor_headers(client):
    client.post("/auth/register", json={
        "email": "editor@test.com", "username": "testeditor",
        "password": "EditorPass123", "role": "editor",
    })
    r = client.post("/auth/login", json={
        "email": "editor@test.com", "password": "EditorPass123",
    })
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.fixture
def viewer_headers(client):
    client.post("/auth/register", json={
        "email": "viewer@test.com", "username": "testviewer",
        "password": "ViewerPass123", "role": "viewer",
    })
    r = client.post("/auth/login", json={
        "email": "viewer@test.com", "password": "ViewerPass123",
    })
    return {"Authorization": f"Bearer {r.json()['access_token']}"}