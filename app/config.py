"""
config.py — ShimonVault application configuration
Reads all settings from environment variables.
Secrets are never hardcoded; values are injected at runtime via .env or EC2 user_data.
"""

import os
from dotenv import load_dotenv

load_dotenv()


def _require(name: str) -> str:
    """Return env var value or raise at startup if truly required."""
    value = os.getenv(name)
    if not value:
        raise ValueError(f"Required environment variable '{name}' is not set")
    return value


# ── Project identity ──────────────────────────────────────────────────────────
PROJECT_NAME = os.getenv("PROJECT_NAME", "shimonvault")
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "production")

# ── Database (MUST use psycopg2 sync driver — asyncpg is incompatible) ────────
# WRITE_DB_URL → AWS RDS primary (all writes go here)
# READ_DB_URL  → on-prem Docker replica via Tailscale (read-only queries)
WRITE_DB_URL = os.getenv(
    "WRITE_DB_URL",
    "postgresql+psycopg2://shimonvault:changeme@localhost:5432/shimonvault"
)
READ_DB_URL = os.getenv(
    "READ_DB_URL",
    "postgresql+psycopg2://shimonvault:changeme@localhost:5432/shimonvault"
)

# ── JWT ───────────────────────────────────────────────────────────────────────
JWT_SECRET_KEY = os.getenv("JWT_SECRET_KEY", "dev-secret-change-in-production")
JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "60"))
# Alias used by auth.py — always keep these in sync
JWT_EXPIRE_MINUTES = ACCESS_TOKEN_EXPIRE_MINUTES

# ── AWS ───────────────────────────────────────────────────────────────────────
AWS_REGION = os.getenv("AWS_REGION", "ap-northeast-2")
AWS_ACCOUNT_ID = os.getenv("AWS_ACCOUNT_ID", "")

# ── S3 ────────────────────────────────────────────────────────────────────────
S3_BUCKET_DOCS = os.getenv("S3_BUCKET_DOCS", f"{PROJECT_NAME}-docs")
S3_BUCKET_REPORTS = os.getenv("S3_BUCKET_REPORTS", f"{PROJECT_NAME}-reports")
S3_PRESIGNED_URL_EXPIRY = int(os.getenv("S3_PRESIGNED_URL_EXPIRY", "900"))  # 15 min

# ── DynamoDB ──────────────────────────────────────────────────────────────────
DYNAMODB_AUDIT_TABLE = os.getenv("DYNAMODB_AUDIT_TABLE", f"{PROJECT_NAME}-audit-log")
DYNAMODB_INCIDENTS_TABLE = os.getenv("DYNAMODB_INCIDENTS_TABLE", f"{PROJECT_NAME}-incidents")
DYNAMODB_MEETINGS_TABLE = os.getenv("DYNAMODB_MEETINGS_TABLE", f"{PROJECT_NAME}-meetings")

# ── SNS ───────────────────────────────────────────────────────────────────────
SNS_TOPIC_SECURITY_ALERT = os.getenv("SNS_TOPIC_SECURITY_ALERT", "")
SNS_TOPIC_CREDENTIAL_STUFFING = os.getenv("SNS_TOPIC_CREDENTIAL_STUFFING", "")
SNS_TOPIC_INFRA_ALERT = os.getenv("SNS_TOPIC_INFRA_ALERT", "")
# Optional — meeting reminders Lambda may not be wired yet
SNS_TOPIC_MEETING_REMINDERS = os.getenv("SNS_TOPIC_MEETING_REMINDERS", "")

# ── Lambda ────────────────────────────────────────────────────────────────────
LAMBDA_BLOCK_IP_NAME = os.getenv("LAMBDA_BLOCK_IP_NAME", f"{PROJECT_NAME}-block-ip")
LAMBDA_LOG_INCIDENT = os.getenv("LAMBDA_LOG_INCIDENT", f"{PROJECT_NAME}-log-incident")

# ── Notifications (Slack + Telegram) ──────────────────────────────────────────
SLACK_WEBHOOK_URL = os.getenv("SLACK_WEBHOOK_URL", "")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")

# ── Rate limiting ─────────────────────────────────────────────────────────────
RATE_LIMIT_LOGIN = os.getenv("RATE_LIMIT_LOGIN", "10/minute")
RATE_LIMIT_DOWNLOAD = os.getenv("RATE_LIMIT_DOWNLOAD", "10/60seconds")
RATE_LIMIT_DEFAULT = os.getenv("RATE_LIMIT_DEFAULT", "100/minute")

# ── Security Group (for Lambda block_ip) ──────────────────────────────────────
APP_SECURITY_GROUP_ID = os.getenv("APP_SECURITY_GROUP_ID", "")

# Rate limit strings used by slowapi decorators
LOGIN_RATE_LIMIT = os.getenv("RATE_LIMIT_LOGIN", "10/minute")
DOWNLOAD_RATE_LIMIT = os.getenv("RATE_LIMIT_DOWNLOAD", "10/60seconds")
DEFAULT_RATE_LIMIT = os.getenv("RATE_LIMIT_DEFAULT", "100/minute")
