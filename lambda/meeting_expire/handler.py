"""
lambda/meeting_expire/handler.py

Triggered by: EventBridge scheduled rule (at meeting end time)
What it does:
  1. Marks the meeting as expired in DynamoDB
  2. Archives the attendance record to S3
  3. Notifies Slack + Telegram that the meeting has been archived
  4. Cleans up the EventBridge rules for this meeting (self-cleanup)
"""

import json
import os
import boto3
from datetime import datetime, timezone

import sys
sys.path.insert(0, "/opt/python")
from notification import notify_all  # noqa: E402

dynamo     = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])
s3         = boto3.client("s3",         region_name=os.environ["AWS_REGION"])
events     = boto3.client("events",     region_name=os.environ["AWS_REGION"])
lambda_svc = boto3.client("lambda",     region_name=os.environ["AWS_REGION"])


def lambda_handler(event, context):
    """
    EventBridge passes event like:
    {
        "meeting_id": "mtg-abc123",
        "meeting_title": "Q3 Review",
        "notify_rule_name": "shimonvault-notify-mtg-abc123",
        "expire_rule_name": "shimonvault-expire-mtg-abc123"
    }
    """
    print("meeting_expire triggered:", json.dumps(event))

    meeting_id         = event.get("meeting_id")
    meeting_title      = event.get("meeting_title", "Meeting")
    notify_rule_name   = event.get("notify_rule_name")
    expire_rule_name   = event.get("expire_rule_name")

    if not meeting_id:
        print("ERROR: meeting_id missing from event")
        return

    # ── Load meeting + attendance from DynamoDB ───────────────────────────────
    meetings_table     = dynamo.Table(os.environ["DYNAMODB_MEETINGS_TABLE"])
    response           = meetings_table.get_item(Key={"meeting_id": meeting_id})
    meeting            = response.get("Item", {})

    if not meeting:
        print(f"Meeting {meeting_id} not found — nothing to expire")
        return

    participants = meeting.get("participants", [])
    attended     = [p for p in participants if p.get("joined")]
    timestamp    = datetime.now(timezone.utc).isoformat()

    # ── Build archive record ──────────────────────────────────────────────────
    archive = {
        "meeting_id":       meeting_id,
        "meeting_title":    meeting_title,
        "organizer":        meeting.get("organizer_id", "unknown"),
        "scheduled_start":  meeting.get("start_time", ""),
        "scheduled_end":    meeting.get("end_time", ""),
        "expired_at":       timestamp,
        "invited_count":    len(participants),
        "attended_count":   len(attended),
        "attendance":       participants,
    }

    # ── Upload archive to S3 ──────────────────────────────────────────────────
    archive_key = f"meetings/{timestamp[:10]}/{meeting_id}-archive.json"
    try:
        s3.put_object(
            Bucket=os.environ["S3_BUCKET_REPORTS"],
            Key=archive_key,
            Body=json.dumps(archive, indent=2, default=str),
            ContentType="application/json",
        )
        print(f"Meeting archive uploaded: s3://{os.environ['S3_BUCKET_REPORTS']}/{archive_key}")
    except Exception as exc:
        print(f"S3 archive upload failed: {exc}")

    # ── Update meeting status to expired ─────────────────────────────────────
    meetings_table.update_item(
        Key={"meeting_id": meeting_id},
        UpdateExpression="SET #s = :s, expired_at = :t, archive_key = :k",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "expired",
            ":t": timestamp,
            ":k": archive_key,
        },
    )

    # ── Notify ────────────────────────────────────────────────────────────────
    message = (
        f"📦 *MEETING ARCHIVED — ShimonVault*\n"
        f"Title: {meeting_title}\n"
        f"Attendance: {len(attended)}/{len(participants)} participants\n"
        f"Archive: saved to S3\n"
        f"Time: {timestamp}"
    )
    notify_all(message)

    # ── Clean up EventBridge rules for this meeting ───────────────────────────
    for rule_name in [notify_rule_name, expire_rule_name]:
        if rule_name:
            _delete_eventbridge_rule(rule_name, context.invoked_function_arn)

    print(f"Meeting {meeting_id} fully expired and archived")


def _delete_eventbridge_rule(rule_name: str, lambda_arn: str):
    """Remove the Lambda target then delete the EventBridge rule."""
    try:
        targets = events.list_targets_by_rule(Rule=rule_name)
        target_ids = [t["Id"] for t in targets.get("Targets", [])]
        if target_ids:
            events.remove_targets(Rule=rule_name, Ids=target_ids)
        events.delete_rule(Name=rule_name)
        print(f"EventBridge rule deleted: {rule_name}")
    except events.exceptions.ResourceNotFoundException:
        print(f"EventBridge rule already gone: {rule_name}")
    except Exception as exc:
        print(f"Failed to delete EventBridge rule {rule_name}: {exc}")
