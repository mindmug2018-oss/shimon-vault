"""
lambda/shared/notification.py

Shared notification helper — include in every Lambda ZIP.
Always sends to BOTH Slack and Telegram simultaneously.
A failed notification never crashes the calling Lambda.
"""

import json
import os
import urllib.request
import urllib.error


def notify_slack(message: str) -> None:
    url = os.environ.get("SLACK_WEBHOOK_URL")
    if not url:
        raise ValueError("SLACK_WEBHOOK_URL not set")
    payload = json.dumps({"text": message}).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        if resp.status not in (200, 204):
            raise RuntimeError(f"Slack returned {resp.status}")


def notify_telegram(message: str) -> None:
    token   = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID")
    if not token or not chat_id:
        raise ValueError("TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set")
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps({
        "chat_id":    chat_id,
        "text":       message,
        "parse_mode": "Markdown",
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        if resp.status != 200:
            raise RuntimeError(f"Telegram returned {resp.status}")


def notify_all(message: str) -> None:
    """Send to all notification channels. Never fail silently."""
    errors = []
    try:
        notify_slack(message)
        print("Slack notification sent")
    except Exception as exc:
        errors.append(f"Slack failed: {exc}")
        print(f"Slack notification error: {exc}")
    try:
        notify_telegram(message)
        print("Telegram notification sent")
    except Exception as exc:
        errors.append(f"Telegram failed: {exc}")
        print(f"Telegram notification error: {exc}")
    if errors:
        # Log errors but do NOT raise — a failed notification must never
        # crash the main Lambda function
        print(f"Notification errors (non-fatal): {errors}")
