"""
lambda/meeting_notify/handler.py

Triggered by: EventBridge scheduled rule (10 minutes before each meeting)
What it does:
  1. Reads the meeting details from DynamoDB
  2. Sends a meeting reminder to all participants via SNS + Slack + Telegram
  3. Updates the meeting status to "notified" in DynamoDB

This is the cloud-native scheduling demo:
  When a meeting is created → EventBridge rule is created with a cron expression
  10 min before start → EventBridge fires THIS Lambda
  Lambda reads meeting state → sends reminders → marks as notified
"""

import json
import os
import boto3
from datetime import datetime, timezone

import sys
sys.path.insert(0, "/opt/python")
from notification import notify_all  # noqa: E402

dynamo = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])
sns    = boto3.client("sns",         region_name=os.environ["AWS_REGION"])


def lambda_handler(event, context):
    """
    EventBridge passes event like:
    {
        "meeting_id": "mtg-abc123",
        "meeting_title": "Q3 Review",
        "meeting_time": "2026-06-10T14:00:00Z",
        "organizer_name": "Admin",
        "join_token": "tok-xyz789",
        "participant_emails": ["alice@example.com", "bob@example.com"]
    }
    """
    print("meeting_notify triggered:", json.dumps(event))

    meeting_id      = event.get("meeting_id")
    meeting_title   = event.get("meeting_title", "Meeting")
    meeting_time    = event.get("meeting_time", "")
    organizer_name  = event.get("organizer_name", "Organizer")
    join_token      = event.get("join_token", "")

    if not meeting_id:
        print("ERROR: meeting_id missing from event")
        return

    # ── Verify meeting still exists and hasn't been cancelled ────────────────
    table = dynamo.Table(os.environ["DYNAMODB_MEETINGS_TABLE"])
    response = table.get_item(Key={"meeting_id": meeting_id})
    meeting = response.get("Item")

    if not meeting:
        print(f"Meeting {meeting_id} not found — skipping notification")
        return

    if meeting.get("status") == "cancelled":
        print(f"Meeting {meeting_id} was cancelled — skipping notification")
        return

    # ── Send SNS to topic (email subscribers) ────────────────────────────────
    sns_message = (
        f"Meeting Reminder: {meeting_title}\n"
        f"Starts in: 10 minutes\n"
        f"Time: {meeting_time}\n"
        f"Organizer: {organizer_name}\n"
        f"Join token: {join_token}\n"
        f"(Token expires at meeting end time)"
    )

    try:
        sns.publish(
            TopicArn=os.environ["SNS_TOPIC_MEETING_REMINDERS"],
            Message=sns_message,
            Subject=f"[ShimonVault] Meeting in 10 minutes: {meeting_title}",
        )
        print(f"SNS reminder sent for meeting {meeting_id}")
    except Exception as exc:
        print(f"SNS publish failed: {exc}")

    # ── Send to Slack + Telegram ──────────────────────────────────────────────
    chat_message = (
        f"📅 *MEETING REMINDER — ShimonVault*\n"
        f"Title: {meeting_title}\n"
        f"Starts in: 10 minutes\n"
        f"Organizer: {organizer_name}\n"
        f"Join token: `{join_token}` (expires at meeting end)\n"
        f"Time: {meeting_time}"
    )
    notify_all(chat_message)

    # ── Update meeting status in DynamoDB ────────────────────────────────────
    table.update_item(
        Key={"meeting_id": meeting_id},
        UpdateExpression="SET #s = :s, notified_at = :t",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "notified",
            ":t": datetime.now(timezone.utc).isoformat(),
        },
    )
    print(f"Meeting {meeting_id} status updated to 'notified'")
