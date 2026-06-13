# shimon-vault/app/routers/audit_router.py

"""
routers/audit_router.py — AuditStream live feed

GET /audit/feed         -> last 100 audit events (all users for admin, own for viewer)
GET /audit/incidents    -> open security incidents (admin only)
GET /audit/my-activity  -> current user's own activity log

These endpoints feed the Grafana JSON API plugin for the live dashboard.
"""

import boto3
from boto3.dynamodb.conditions import Attr
from fastapi import APIRouter, Depends

import config
from auth import get_current_user, require_role
from models import User, UserRole

router = APIRouter()

_dynamodb = None


def _get_audit_table():
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.resource("dynamodb", region_name=config.AWS_REGION)
    return _dynamodb.Table(config.DYNAMODB_AUDIT_TABLE)


def _get_incidents_table():
    dynamodb = boto3.resource("dynamodb", region_name=config.AWS_REGION)
    return dynamodb.Table(config.DYNAMODB_INCIDENTS_TABLE)


@router.get("/feed")
def get_audit_feed(
    limit: int = 100,
    current_user: User = Depends(get_current_user),
):
    """
    Return the most recent audit events.
    Admin sees all events. Non-admin sees only their own.
    Used by Grafana JSON API plugin for the live feed panel.
    """
    table = _get_audit_table()
    try:
        if current_user.role == UserRole.ADMIN:
            # Admin sees everything
            response = table.scan(Limit=limit)
        else:
            # Non-admin sees only their own events
            response = table.scan(
                FilterExpression=Attr("user_id").eq(str(current_user.id)),
                Limit=limit,
            )
        items = sorted(
            response.get("Items", []),
            key=lambda x: x.get("created_at", ""),
            reverse=True,
        )
    except Exception as exc:
        print(f"[audit_router] DynamoDB unavailable in get_audit_feed: {exc}")
        items = []

    return {"events": items, "count": len(items)}


@router.get("/incidents")
def get_incidents(
    current_user: User = Depends(require_role(UserRole.ADMIN)),
):
    """
    Return open security incidents. Admin only.
    Shown in the Grafana "Active Incidents" panel with red severity color.
    """
    table = _get_incidents_table()
    try:
        response = table.scan(
            FilterExpression=Attr("status").eq("active"),
        )
        incidents = sorted(
            response.get("Items", []),
            key=lambda x: x.get("created_at", ""),
            reverse=True,
        )
    except Exception as exc:
        print(f"[audit_router] DynamoDB unavailable in get_incidents: {exc}")
        incidents = []

    return {"incidents": incidents, "count": len(incidents)}


@router.get("/my-activity")
def get_my_activity(
    current_user: User = Depends(get_current_user),
):
    """Current user's own activity. Every user can see their own history."""
    table = _get_audit_table()
    try:
        response = table.scan(
            FilterExpression=Attr("user_id").eq(str(current_user.id)),
            Limit=50,
        )
        items = sorted(
            response.get("Items", []),
            key=lambda x: x.get("created_at", ""),
            reverse=True,
        )
    except Exception as exc:
        print(f"[audit_router] DynamoDB unavailable in get_my_activity: {exc}")
        items = []

    return {"events": items, "count": len(items)}
