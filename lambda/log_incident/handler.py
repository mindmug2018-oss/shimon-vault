"""
lambda/log_incident/handler.py

Triggered by SNS topic: shimonvault-security-alert
What it does:
  1. Parses the security event from SNS
  2. Writes a full incident record to DynamoDB incidents table
  3. Uploads a JSON incident report to S3 shimonvault-reports bucket
  4. Posts formatted alert to Slack + Telegram
"""

import json
import os
import boto3
from datetime import datetime, timezone

# Add /opt/python to path when running on Lambda with a layer
import sys
sys.path.insert(0, "/opt/python")
from notification import notify_all  # noqa: E402  (after sys.path fix)

dynamo = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])
s3     = boto3.client("s3",         region_name=os.environ["AWS_REGION"])


def lambda_handler(event, context):
    print("log_incident triggered:", json.dumps(event))
    for record in event.get("Records", []):
        try:
            payload = json.loads(record["Sns"]["Message"])
            process(payload)
        except Exception as exc:
            print(f"ERROR: {exc}")


def process(payload: dict):
    # Support both direct security incident payloads and CloudWatch alarm payloads
    if "AlarmName" in payload:
        # CloudWatch alarm format
        alarm_name = payload.get("AlarmName", "unknown")
        new_state = payload.get("NewStateValue", "UNKNOWN")
        reason = payload.get("NewStateReason", "")
        incident_type = f"cloudwatch_alarm_{alarm_name.replace('-', '_')}"
        severity = "HIGH" if new_state == "ALARM" else "LOW"
        attacking_ip = "N/A"
        user_id = "N/A"
        resource_path = alarm_name
        details = {
            "alarm_name": alarm_name,
            "state": new_state,
            "reason": reason,
            "region": payload.get("Region", ""),
        }
    else:
        # Direct security incident format
        incident_type = payload.get("incident_type", "unknown")
        severity      = payload.get("severity", "MEDIUM")
        attacking_ip  = payload.get("attacking_ip", "N/A")
        user_id       = payload.get("user_id", "N/A")
        resource_path = payload.get("resource_path", "N/A")
        details       = payload.get("details", {})
    timestamp: str      = datetime.now(timezone.utc).isoformat()
    incident_id: str    = f"{incident_type}-{int(datetime.now().timestamp())}"

    # ── 1. Write to DynamoDB ─────────────────────────────────────────────────
    incident_record = {
        "id":            incident_id,
        "created_at":    timestamp,
        "incident_id":   incident_id,
        "incident_type": incident_type,
        "severity":      severity,
        "attacking_ip":  attacking_ip,
        "user_id":       user_id,
        "resource_path": resource_path,
        "details":       details,
        "timestamp":     timestamp,
        "status":        "active",
    }
    table = dynamo.Table(os.environ["DYNAMODB_INCIDENTS_TABLE"])
    table.put_item(Item=incident_record)
    print(f"DynamoDB incident written: {incident_id}")

    # ── 2. Upload JSON report to S3 ──────────────────────────────────────────
    report_key = f"incidents/{timestamp[:10]}/{incident_id}.json"
    s3.put_object(
        Bucket=os.environ["S3_BUCKET_REPORTS"],
        Key=report_key,
        Body=json.dumps(incident_record, indent=2),
        ContentType="application/json",
    )
    print(f"S3 report uploaded: s3://{os.environ['S3_BUCKET_REPORTS']}/{report_key}")

    # ── 3. Notify ────────────────────────────────────────────────────────────
    severity_emoji = {"HIGH": "\U0001F6A8", "MEDIUM": "\u26A0\uFE0F", "LOW": "\u2139\uFE0F"}.get(severity, "\u26A0\uFE0F")
    if "AlarmName" in payload:
        alarm_name = details.get("alarm_name", resource_path)
        state = details.get("state", "UNKNOWN")
        reason = details.get("reason", "")
        state_emoji = "\U0001F534" if state == "ALARM" else "\u2705"
        message = (
            f"{state_emoji} *INFRASTRUCTURE ALERT -- ShimonVault*\n"
            f"Alarm: `{alarm_name}`\n"
            f"State: {state}\n"
            f"Reason: {reason[:200]}\n"
            f"Region: {details.get('region', '')}\n"
            f"Report: s3://{os.environ['S3_BUCKET_REPORTS']}/{report_key}\n"
            f"Time: {timestamp}"
        )
    else:
        message = (
            f"{severity_emoji} *SECURITY INCIDENT -- ShimonVault*\n"
            f"ID: `{incident_id}`\n"
            f"Type: {incident_type.replace('_', ' ').title()}\n"
            f"Severity: {severity}\n"
            f"IP: `{attacking_ip}`\n"
            f"User: `{user_id}`\n"
            f"Resource: `{resource_path}`\n"
            f"Report: s3://{os.environ['S3_BUCKET_REPORTS']}/{report_key}\n"
            f"Time: {timestamp}"
        )
    notify_all(message)
