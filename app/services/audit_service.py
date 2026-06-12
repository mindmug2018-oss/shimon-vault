# shimon-vault/app/services/audit_service.py

"""
services/audit_service.py — writes audit events to DynamoDB

DynamoDB table: audit-log (created by terraform/dynamodb.tf)
Table schema:
  PK:  id          (String, UUID)
  SK:  created_at  (String, ISO-8601 timestamp)
  GSI: event_type-index (for querying "all login failures in last hour")

Why DynamoDB AND PostgreSQL?
  DynamoDB: millisecond writes, never blocks the app, survives DB outages
  PostgreSQL audit_events table: kept in sync for complex SQL reports
  Grafana reads from DynamoDB via the JSON API plugin for the live feed.
"""

import json
import uuid
from datetime import datetime, timezone
from typing import Optional

import boto3
from botocore.exceptions import ClientError

import config
from models import AuditEventType

# Lazy-initialize the DynamoDB resource
# (boto3 reads AWS credentials from the EC2 instance profile automatically)
_dynamodb = None

def _get_table():
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.resource("dynamodb", region_name=config.AWS_REGION)
    return _dynamodb.Table(config.DYNAMODB_AUDIT_TABLE)


def write_event(
    event_type: AuditEventType,
    ip_address: Optional[str] = None,
    resource: Optional[str] = None,
    detail: Optional[str] = None,
    severity: str = "info",
    user_id: Optional[str] = None,
) -> bool:
    """
    Write one audit event to DynamoDB.
    Returns True on success, False on failure.
    NEVER raises — a logging failure must never crash the app.

    Example item written:
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "created_at": "2026-06-02T10:30:00.123456+00:00",
      "event_type": "doc_download",
      "ip_address": "203.0.113.42",
      "resource": "/docs/download/abc123",
      "severity": "info",
      "user_id": "user-uuid-here",
      "detail": "{\"filename\": \"report.pdf\"}"
    }
    """
    try:
        table = _get_table()
        now = datetime.now(timezone.utc).isoformat()
        item = {
            "id":         str(uuid.uuid4()),
            "created_at": now,
            "event_type": event_type.value,
            "severity":   severity,
        }
        if ip_address: item["ip_address"] = ip_address
        if resource:   item["resource"]   = resource
        if detail:     item["detail"]     = detail
        if user_id:    item["user_id"]    = user_id

        table.put_item(Item=item)
        return True

    except ClientError as e:
        print(f"[audit_service] DynamoDB ClientError: {e.response['Error']['Message']}")
        return False
    except Exception as e:
        print(f"[audit_service] Unexpected error writing audit event: {e}")
        return False


def write_security_incident(
    incident_type: str,
    ip_address: str,
    detail: dict,
    user_id: Optional[str] = None,
) -> bool:
    """
    Write a high-severity incident to the incidents DynamoDB table.
    This is separate from the audit-log table so Grafana can show them
    in a dedicated "Active Incidents" panel.
    Also triggers the SNS alert which fires the Lambda block_ip function.
    """
    try:
        dynamodb = boto3.resource("dynamodb", region_name=config.AWS_REGION)
        table = dynamodb.Table(config.DYNAMODB_INCIDENTS_TABLE)
        now = datetime.now(timezone.utc).isoformat()

        table.put_item(Item={
            "id":            str(uuid.uuid4()),
            "created_at":    now,
            "incident_type": incident_type,
            "ip_address":    ip_address,
            "detail":        json.dumps(detail),
            "status":        "open",
            "user_id":       user_id or "unknown",
        })

        # Also write to audit-log for the unified feed
        write_event(
            event_type=AuditEventType.SUSPICIOUS,
            ip_address=ip_address,
            resource=f"incident:{incident_type}",
            detail=json.dumps(detail),
            severity="critical",
            user_id=user_id,
        )
        return True

    except Exception as e:
        print(f"[audit_service] Failed to write security incident: {e}")
        return False