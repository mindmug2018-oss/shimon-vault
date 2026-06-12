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
    incident_type: str  = payload.get("incident_type", "unknown")
    severity: str       = payload.get("severity", "MEDIUM")
    attacking_ip: str   = payload.get("attacking_ip", "N/A")
    user_id: str        = payload.get("user_id", "N/A")
    resource_path: str  = payload.get("resource_path", "N/A")
    details: dict       = payload.get("details", {})
    timestamp: str      = datetime.now(timezone.utc).isoformat()
    incident_id: str    = f"{incident_type}-{int(datetime.now().timestamp())}"

    # ── 1. Write to DynamoDB ─────────────────────────────────────────────────
    incident_record = {
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
    severity_emoji = {"HIGH": "🚨", "MEDIUM": "⚠️", "LOW": "ℹ️"}.get(severity, "⚠️")
    message = (
        f"{severity_emoji} *SECURITY INCIDENT — ShimonVault*\n"
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
