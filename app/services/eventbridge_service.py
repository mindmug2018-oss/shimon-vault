"""
services/eventbridge_service.py — EventBridge meeting scheduler

Called by meetings_router when a meeting is created or cancelled.
Creates one-time scheduled EventBridge rules that fire Lambda functions
at specific times (10 min before meeting starts, and at meeting end time).

How EventBridge one-time rules work:
  - Cron expression at(yyyy-mm-ddThh:mm:ss) fires EXACTLY ONCE at that UTC time
  - EventBridge passes the meeting_id as input to the Lambda
  - Lambda reads the meeting from DynamoDB and takes action
  - After firing, the rule is disabled but stays in EventBridge — we clean it up

Why not just use a background thread or cron in the app?
  - App instances restart (deploy, scale-out, crash)
  - Background threads die with the process
  - EventBridge is serverless and runs outside our app — it is always reliable
"""

import json
from datetime import datetime, timedelta, timezone
from typing import Optional

import boto3
from botocore.exceptions import ClientError

import config

_events_client = None


def _get_client():
    global _events_client
    if _events_client is None:
        _events_client = boto3.client("events", region_name=config.AWS_REGION)
    return _events_client


def _to_at_expression(dt: datetime) -> str:
    """
    Convert a datetime to an EventBridge at() cron expression.
    EventBridge requires UTC time in format: at(yyyy-mm-ddThh:mm:ss)
    """
    utc = dt.astimezone(timezone.utc)
    return f"at({utc.strftime('%Y-%m-%dT%H:%M:%S')})"


def schedule_meeting_notify(
    meeting_id: str,
    scheduled_at: datetime,
    notify_lambda_arn: str,
) -> Optional[str]:
    """
    Create an EventBridge rule that fires the meeting_notify Lambda
    10 minutes before the meeting starts.

    Returns the rule name (stored on the Meeting model so we can cancel it).
    Returns None if scheduling fails (non-fatal — the meeting still saves).
    """
    notify_time = scheduled_at - timedelta(minutes=10)
    now = datetime.now(timezone.utc)

    # If the meeting is less than 10 minutes away, fire immediately (or skip)
    if notify_time <= now:
        print(f"[eventbridge] Meeting {meeting_id} starts too soon to schedule a reminder")
        return None

    rule_name = f"{config.AWS_REGION[:2]}-{meeting_id[:8]}-notify"

    try:
        client = _get_client()

        # Create the scheduled rule
        client.put_rule(
            Name=rule_name,
            ScheduleExpression=_to_at_expression(notify_time),
            State="ENABLED",
            Description=f"ShimonVault meeting reminder for {meeting_id}",
        )

        # Add the Lambda as the target, passing meeting_id as input
        client.put_targets(
            Rule=rule_name,
            Targets=[{
                "Id":  f"meeting-notify-{meeting_id[:8]}",
                "Arn": notify_lambda_arn,
                "Input": json.dumps({
                    "source":     "shimonvault.meeting-reminder",
                    "meeting_id": meeting_id,
                }),
            }],
        )

        return rule_name

    except ClientError as e:
        print(f"[eventbridge] Failed to schedule meeting notify for {meeting_id}: {e}")
        return None


def schedule_meeting_expire(
    meeting_id: str,
    ends_at: datetime,
    expire_lambda_arn: str,
) -> Optional[str]:
    """
    Create an EventBridge rule that fires the meeting_expire Lambda
    exactly at meeting end time.
    """
    now = datetime.now(timezone.utc)
    if ends_at <= now:
        return None

    rule_name = f"{config.AWS_REGION[:2]}-{meeting_id[:8]}-expire"

    try:
        client = _get_client()

        client.put_rule(
            Name=rule_name,
            ScheduleExpression=_to_at_expression(ends_at),
            State="ENABLED",
            Description=f"ShimonVault meeting expiry for {meeting_id}",
        )

        client.put_targets(
            Rule=rule_name,
            Targets=[{
                "Id":  f"meeting-expire-{meeting_id[:8]}",
                "Arn": expire_lambda_arn,
                "Input": json.dumps({
                    "source":     "shimonvault.meeting-expire",
                    "meeting_id": meeting_id,
                }),
            }],
        )

        return rule_name

    except ClientError as e:
        print(f"[eventbridge] Failed to schedule meeting expire for {meeting_id}: {e}")
        return None


def cancel_meeting_rule(rule_name: str) -> bool:
    """
    Remove an EventBridge rule (called when a meeting is cancelled).
    Must remove targets first, then delete the rule.
    Returns True on success, False on error.
    """
    if not rule_name:
        return True

    try:
        client = _get_client()

        # List targets first — can't delete rule with targets attached
        targets = client.list_targets_by_rule(Rule=rule_name).get("Targets", [])
        if targets:
            client.remove_targets(
                Rule=rule_name,
                Ids=[t["Id"] for t in targets],
            )

        client.delete_rule(Name=rule_name)
        return True

    except ClientError as e:
        # Rule may have already fired and been cleaned up — that is fine
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            return True
        print(f"[eventbridge] Failed to cancel rule {rule_name}: {e}")
        return False
